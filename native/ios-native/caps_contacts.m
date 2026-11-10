// contacts: look someone up in the user's address book. Read-only.
//
// **What it is for.** "Text Zhang San" needs his number, and "email the
// landlord" needs an address. So `search` answers with phones and emails already
// in each entry, and `get` exists only for the rest of a card — most lookups end
// after one call.
//
// **Why there is no write here.** iOS has one contacts permission and it covers
// reading and writing alike, so "the agent will not touch my address book" is
// ours to keep rather than the system's — the same position as photos. It is
// kept the same way: there is no `CNSaveRequest` in this file, so there is
// nothing to gate and the capability declares no `writeOps`.
//
// **Why the caller names the field.** A query like "138" could be part of a
// number or a company name, and "li@" could be either too. Sniffing the query to
// decide would be this file answering a question the caller has not asked, and
// then patching the sniffing forever (§4.5). So `search` takes exactly one of
// `name`, `phone`, `email`, each mapped to the predicate Apple wrote for it, and
// every match comes back in the store's order — which contact was meant is the
// caller's call, and the user's.
//
// **Limited access is an answer, not an error.** From iOS 18 the user can share
// a few contacts instead of the address book, and the store then answers every
// fetch from those few without mentioning it. "No match" among five shared
// contacts reads exactly like "that person is not in your contacts", so every
// reply carries `access`, and a limited one carries a sentence the agent can
// read out — the same arrangement as caps_photos.m.
//
// **What is never fetched.** The note field needs an entitlement Apple grants on
// request and this app does not have; asking for `CNContactNoteKey` without it
// fails the whole fetch, not just that field. Pictures are left out because a
// face is of no use to a caller that wanted a phone number.
#import "dsh_ios_native.h"
#import <Contacts/Contacts.h>

/// A common surname matches hundreds of cards. The cap is about the size of the
/// reply, not about which matches matter, so `total` and `truncated` always say
/// what was left out (§4.5).
static const NSUInteger kDefaultLimit = 25;
static const NSUInteger kMaxLimit = 100;

static NSString *const kDeniedMessage =
    @"contacts access is off for this app. The user can turn it on in Settings > Privacy & Security > "
     "Contacts. iOS only asks once, so it cannot be requested again from here";

static NSString *const kNotEnabledMessage =
    @"the user has not switched contacts access on for this app yet. Nothing was read. Tell them they "
     "can turn it on themselves under Device capabilities, which is in the app's sidebar — only "
     "they can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// Said out loud on every limited reply. Without it an empty search reads as a
/// fact about the user's address book when it is a fact about the few cards they
/// shared, and a model relaying "she is not in your contacts" would be repeating
/// our mistake to the one person who knows she is.
static NSString *const kLimitedNote =
    @"the user shared a selected set of contacts with this app rather than the whole address book, "
     "so this describes that selection only: no match here means no match among the shared "
     "contacts, and a person they did not share is not missing from their contacts but invisible "
     "to this app. Say so rather than telling them the person is not in their contacts. They can "
     "change the selection in Settings > Privacy & Security > Contacts.";

/// The store's fetches are synchronous and go to the contacts database. Neither
/// Node's thread nor the main thread is a place to wait for that.
static dispatch_queue_t contacts_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.contacts",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

static CNContactStore *contact_store(void) {
  static CNContactStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ store = [CNContactStore new]; });
  return store;
}

#pragma mark - Authorisation

typedef NS_ENUM(NSInteger, ContactsAccess) {
  ContactsAccessNotAsked,
  ContactsAccessRefused,
  ContactsAccessFull,
  ContactsAccessLimited,
};

static ContactsAccess current_access(void) {
  CNAuthorizationStatus status = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
  // Compared outside the switch because the constant only exists from iOS 18 and
  // the deployment target is 17. Below 18 the system cannot return it at all.
  if (@available(iOS 18.0, *)) {
    if (status == CNAuthorizationStatusLimited) return ContactsAccessLimited;
  }
  switch (status) {
    case CNAuthorizationStatusAuthorized:
      return ContactsAccessFull;
    case CNAuthorizationStatusDenied:
    case CNAuthorizationStatusRestricted:
      return ContactsAccessRefused;
    case CNAuthorizationStatusNotDetermined:
    default:
      return ContactsAccessNotAsked;
  }
}

/// Check contacts authorisation and run `next` with the outcome. Never prompts:
/// `requestAccessForEntityType:` *is* the prompt, so calling it here would let
/// whichever caller reads first decide when the user is asked, and the user gets
/// asked exactly once per install (§5.5).
///
/// `limited` rides along rather than being folded into `granted` because the two
/// answers need different sentences, and collapsing them is precisely how five
/// shared cards end up presented as an address book.
static void require_authorization(void (^next)(BOOL granted, BOOL limited, NSString *error)) {
  switch (current_access()) {
    case ContactsAccessFull:
      next(YES, NO, nil);
      return;
    case ContactsAccessLimited:
      next(YES, YES, nil);
      return;
    case ContactsAccessRefused:
      next(NO, NO, kDeniedMessage);
      return;
    case ContactsAccessNotAsked:
      next(NO, NO, kNotEnabledMessage);
      return;
  }
}

void DshContactsGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  ContactsAccess standing = current_access();
  if (standing != ContactsAccessNotAsked) {
    // Already answered. iOS will not ask again, so report the standing answer
    // instead of raising a dialog that will not appear.
    BOOL granted = standing == ContactsAccessFull || standing == ContactsAccessLimited;
    done(granted, granted ? nil : kDeniedMessage);
    return;
  }
  dsh_native_on_main(^{
    [contact_store() requestAccessForEntityType:CNEntityTypeContacts
                              completionHandler:^(BOOL ok, NSError *error) {
      // The status is read back instead of trusting `ok`: it is what every later
      // call is judged by, so the screen and the handler cannot disagree about
      // what the user just chose. "Select Contacts…" comes back granted, because
      // it is — a limited selection is access, and every reply says which kind.
      (void)ok;
      (void)error;
      ContactsAccess chosen = current_access();
      BOOL granted = chosen == ContactsAccessFull || chosen == ContactsAccessLimited;
      done(granted, granted ? nil : kDeniedMessage);
    }];
  });
}

#pragma mark - Reading

/// What `search` fetches for every match. The formatter's descriptor has to be
/// here: `CNContactFormatter` raises on a contact fetched without the keys it
/// wants, and which keys those are depends on the user's name-order settings.
static NSArray<id<CNKeyDescriptor>> *summary_keys(void) {
  return @[
    [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
    CNContactOrganizationNameKey,
    CNContactPhoneNumbersKey,
    CNContactEmailAddressesKey,
  ];
}

static NSArray<id<CNKeyDescriptor>> *detail_keys(void) {
  return [summary_keys() arrayByAddingObjectsFromArray:@[
    CNContactGivenNameKey,
    CNContactFamilyNameKey,
    CNContactMiddleNameKey,
    CNContactNicknameKey,
    CNContactJobTitleKey,
    CNContactDepartmentNameKey,
    CNContactPostalAddressesKey,
    CNContactBirthdayKey,
    CNContactUrlAddressesKey,
  ]];
}

/// One labelled string. The label goes through Apple's localiser because the
/// stored form of a built-in label is `_$!<Mobile>!$_`, which tells a model
/// nothing; a label the user typed comes through unchanged. An entry with no
/// label gets no `label` key rather than an invented "other".
static NSMutableDictionary *labeled_json(CNLabeledValue *entry, NSString *value) {
  NSMutableDictionary *json = [@{@"value": value ?: @""} mutableCopy];
  if (entry.label != nil) json[@"label"] = [CNLabeledValue localizedStringForLabel:entry.label];
  return json;
}

static NSMutableDictionary *summary_json(CNContact *contact) {
  NSMutableArray *phones = [NSMutableArray arrayWithCapacity:contact.phoneNumbers.count];
  for (CNLabeledValue<CNPhoneNumber *> *entry in contact.phoneNumbers) {
    // As the user typed it. Normalising to one format would be a rewrite, and
    // whether "+86" belongs in front is exactly what the caller may need to see.
    [phones addObject:labeled_json(entry, entry.value.stringValue)];
  }
  NSMutableArray *emails = [NSMutableArray arrayWithCapacity:contact.emailAddresses.count];
  for (CNLabeledValue<NSString *> *entry in contact.emailAddresses) {
    [emails addObject:labeled_json(entry, entry.value)];
  }
  return [@{
    @"id": contact.identifier,
    // Empty for a card with no name fields at all, which exists — a bare number
    // saved from a call log. Left empty rather than filled from another field.
    @"name": [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName] ?: @"",
    @"organization": contact.organizationName ?: @"",
    @"phones": phones,
    @"emails": emails,
  } mutableCopy];
}

/// `{year?, month, day}`. Most birthdays in an address book have no year, and
/// Contacts says so with NSDateComponentUndefined rather than with nil — which is
/// NSIntegerMax and would cross into JSON as a nineteen-digit year.
static NSDictionary *birthday_json(NSDateComponents *birthday) {
  if (birthday == nil || birthday.month == NSDateComponentUndefined
      || birthday.day == NSDateComponentUndefined) {
    return nil;
  }
  NSMutableDictionary *json = [@{@"month": @(birthday.month), @"day": @(birthday.day)} mutableCopy];
  if (birthday.year != NSDateComponentUndefined) json[@"year"] = @(birthday.year);
  return json;
}

static NSDictionary *detail_json(CNContact *contact) {
  NSMutableDictionary *json = summary_json(contact);
  json[@"givenName"] = contact.givenName ?: @"";
  json[@"familyName"] = contact.familyName ?: @"";
  json[@"middleName"] = contact.middleName ?: @"";
  json[@"nickname"] = contact.nickname ?: @"";
  json[@"jobTitle"] = contact.jobTitle ?: @"";
  json[@"department"] = contact.departmentName ?: @"";

  NSMutableArray *addresses = [NSMutableArray arrayWithCapacity:contact.postalAddresses.count];
  for (CNLabeledValue<CNPostalAddress *> *entry in contact.postalAddresses) {
    CNPostalAddress *address = entry.value;
    NSMutableDictionary *item = [@{
      // Apple's formatter orders the parts the way the address's own country
      // writes them, which is not something to reassemble by hand from the
      // fields. It answers with line breaks in it, and they are left in.
      @"formatted": [CNPostalAddressFormatter stringFromPostalAddress:address
                                                                style:CNPostalAddressFormatterStyleMailingAddress],
      @"street": address.street ?: @"",
      @"subLocality": address.subLocality ?: @"",
      @"city": address.city ?: @"",
      @"subAdministrativeArea": address.subAdministrativeArea ?: @"",
      @"state": address.state ?: @"",
      @"postalCode": address.postalCode ?: @"",
      @"country": address.country ?: @"",
      @"isoCountryCode": address.ISOCountryCode ?: @"",
    } mutableCopy];
    if (entry.label != nil) item[@"label"] = [CNLabeledValue localizedStringForLabel:entry.label];
    [addresses addObject:item];
  }
  json[@"addresses"] = addresses;

  NSDictionary *birthday = birthday_json(contact.birthday);
  if (birthday != nil) json[@"birthday"] = birthday;

  NSMutableArray *urls = [NSMutableArray arrayWithCapacity:contact.urlAddresses.count];
  for (CNLabeledValue<NSString *> *entry in contact.urlAddresses) {
    [urls addObject:labeled_json(entry, entry.value)];
  }
  json[@"urls"] = urls;
  return json;
}

static void search_contacts(NSDictionary *args, DshNativeReply reply) {
  NSString *field = nil, *query = nil;
  NSUInteger given = 0;
  for (NSString *key in @[@"name", @"phone", @"email"]) {
    NSString *value = args[key];
    if (value == nil) continue;
    if (![value isKindOfClass:NSString.class] || value.length == 0) {
      reply(nil, [NSString stringWithFormat:@"'%@' must be a non-empty string", key]);
      return;
    }
    given++;
    field = key;
    query = value;
  }
  if (given != 1) {
    reply(nil, @"search needs exactly one of 'name', 'phone' or 'email'. Say which field the query "
                "is for; it is not guessed from how the query looks");
    return;
  }
  NSNumber *limit = args[@"limit"];
  NSUInteger wanted = kDefaultLimit;
  if (limit != nil) {
    if (![limit isKindOfClass:NSNumber.class] || limit.integerValue < 1) {
      reply(nil, @"'limit' must be at least 1");
      return;
    }
    wanted = MIN((NSUInteger)limit.integerValue, kMaxLimit);
  }

  require_authorization(^(BOOL granted, BOOL limited, NSString *accessError) {
    if (!granted) {
      reply(nil, accessError);
      return;
    }
    dispatch_async(contacts_queue(), ^{
      // Each field has a predicate Apple wrote for it, and the matching rule is
      // theirs: several words in a name, case-insensitive email, a best effort
      // across country codes for a number. Nothing is layered on top.
      NSPredicate *predicate = nil;
      if ([field isEqualToString:@"name"]) {
        predicate = [CNContact predicateForContactsMatchingName:query];
      } else if ([field isEqualToString:@"phone"]) {
        predicate = [CNContact predicateForContactsMatchingPhoneNumber:
                     [CNPhoneNumber phoneNumberWithStringValue:query]];
      } else {
        predicate = [CNContact predicateForContactsMatchingEmailAddress:query];
      }

      NSError *fetchError = nil;
      NSArray<CNContact *> *found = [contact_store() unifiedContactsMatchingPredicate:predicate
                                                                          keysToFetch:summary_keys()
                                                                                error:&fetchError];
      if (found == nil) {
        reply(nil, fetchError.localizedDescription ?: @"the address book could not be read");
        return;
      }

      // The first `wanted` in the order the store returned them. No sort and no
      // "closest name first": with two Zhang Sans the right one is whichever the
      // user says it is.
      NSMutableArray *contacts = [NSMutableArray arrayWithCapacity:MIN(found.count, wanted)];
      for (NSUInteger i = 0; i < found.count && contacts.count < wanted; i++) {
        [contacts addObject:summary_json(found[i])];
      }
      NSMutableDictionary *result = [@{
        @"contacts": contacts,
        @"total": @(found.count),
        // The (BOOL) cast is load-bearing: a C comparison is an int, and without
        // it the JSON carries 0/1 where a model expects true/false.
        @"truncated": @((BOOL)(found.count > contacts.count)),
        @"access": limited ? @"limited" : @"full",
        // A name query is the caller's own words, so it is shown. A number or an
        // address that matched is a line off somebody's card, and the audit list
        // is the user's view of what reached their data, not a second copy of it.
        @"auditSummary": [field isEqualToString:@"name"]
          ? [NSString stringWithFormat:@"%@ · %lu", query, (unsigned long)found.count]
          : [NSString stringWithFormat:@"%@ · %lu", field, (unsigned long)found.count],
      } mutableCopy];
      if (limited) result[@"note"] = kLimitedNote;
      reply(result, nil);
    });
  });
}

static void get_contact(NSDictionary *args, DshNativeReply reply) {
  NSString *identifier = args[@"id"];
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"get needs the contact's 'id', as `search` returned it");
    return;
  }

  require_authorization(^(BOOL granted, BOOL limited, NSString *accessError) {
    if (!granted) {
      reply(nil, accessError);
      return;
    }
    dispatch_async(contacts_queue(), ^{
      // The identifiers predicate rather than `unifiedContactWithIdentifier:`:
      // it answers an unknown id with an empty array, so "no such contact" does
      // not have to be told apart from a real failure by its error code.
      NSError *fetchError = nil;
      NSArray<CNContact *> *found =
        [contact_store() unifiedContactsMatchingPredicate:[CNContact predicateForContactsWithIdentifiers:@[identifier]]
                                              keysToFetch:detail_keys()
                                                    error:&fetchError];
      if (found == nil) {
        reply(nil, fetchError.localizedDescription ?: @"the address book could not be read");
        return;
      }
      CNContact *contact = found.firstObject;
      if (contact == nil) {
        // Two different facts, said differently: a stale id, or an id for a card
        // that exists and is simply outside what the user shared.
        reply(nil, limited
              ? @"no contact with that id among the ones the user shared. Under a limited selection "
                 "only those are visible to this app, so an id from anywhere else will not resolve. "
                 "They can change the selection in Settings > Privacy & Security > Contacts."
              : @"no contact with that id; it may have been deleted or merged into another card, "
                 "so run `search` again");
        return;
      }

      NSDictionary *card = detail_json(contact);
      NSString *name = card[@"name"];
      NSMutableDictionary *result = [@{
        @"contact": card,
        @"access": limited ? @"limited" : @"full",
        // Whose card, and nothing off it. A card with no name is recorded as a
        // count of one rather than by its number.
        @"auditSummary": name.length > 0 ? name : @"1",
      } mutableCopy];
      if (limited) result[@"note"] = kLimitedNote;
      reply(result, nil);
    });
  });
}

void dsh_native_contacts(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"search"]) { search_contacts(args, reply); return; }
  if ([op isEqualToString:@"get"]) { get_contact(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"contacts has no operation '%@'", op]);
}
