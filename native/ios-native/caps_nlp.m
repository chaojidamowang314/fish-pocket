// nlp: the parts of the NaturalLanguage framework a language model cannot do
// better for itself. On device, no network, no permission, nothing stored.
//
// **Most of this framework is not worth exposing**, and that is worth writing
// down so nobody adds it back. The caller is a large language model: it reads
// sentiment, splits words and spots names better than NLTagger does, in more
// languages. Handing it `tokenize` or `sentiment` would be handing it a worse
// copy of something it already has — it would call them, get a poorer answer,
// and have no way to know it was poorer.
//
// What survives that test is work the model cannot do *at the size it matters*,
// or cannot do at all:
//
//   - `language` and `entities` — the model is better per document, but it has
//     to read the document to be better. Classifying five thousand files is a
//     loop here and five thousand requests otherwise, and nothing leaves the
//     phone.
//   - `similar` — a model cannot produce an embedding vector, and could not
//     compare a thousand of them in its context if it could. Ranking a corpus
//     by meaning is the one thing here that is not a worse copy of the caller.
#import "dsh_ios_native.h"
#import <NaturalLanguage/NaturalLanguage.h>

/// Long inputs are the point — that is when running locally beats asking the
/// model — but an unbounded string crossing the N-API boundary is not.
static const NSUInteger kMaxTextLength = 200000;
static const NSUInteger kMaxItems = 2000;
/// `similar` holds every candidate and embeds each one, so it is capped lower
/// than a single string's length.
static const NSUInteger kMaxCandidates = 2000;
static const NSUInteger kMaxCandidateLength = 5000;

static NSString *text_arg(NSDictionary *args, NSString **error) {
  NSString *text = args[@"text"];
  if (![text isKindOfClass:NSString.class] || text.length == 0) {
    *error = @"this operation needs a non-empty 'text'";
    return nil;
  }
  if (text.length > kMaxTextLength) {
    *error = [NSString stringWithFormat:@"'text' is %lu characters; the limit is %lu",
              (unsigned long)text.length, (unsigned long)kMaxTextLength];
    return nil;
  }
  return text;
}

static NLLanguage dominant_language(NSString *text) {
  NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
  [recognizer processString:text];
  return recognizer.dominantLanguage;
}

static void identify_language(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSString *text = text_arg(args, &error);
  if (text == nil) { reply(nil, error); return; }

  NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
  [recognizer processString:text];
  NSDictionary<NLLanguage, NSNumber *> *hypotheses = [recognizer languageHypothesesWithMaximum:5];
  NSArray *sorted = [hypotheses.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [hypotheses[b] compare:hypotheses[a]];
  }];
  NSMutableArray *ranked = [NSMutableArray array];
  for (NLLanguage language in sorted) {
    [ranked addObject:@{@"language": language, @"confidence": hypotheses[language]}];
  }
  // Nil for a string with nothing to go on — digits, emoji, a URL. Saying so
  // beats naming whichever language scored least badly.
  reply(@{@"language": recognizer.dominantLanguage ?: NSNull.null,
          @"hypotheses": ranked}, nil);
}

static void named_entities(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSString *text = text_arg(args, &error);
  if (text == nil) { reply(nil, error); return; }

  NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[NLTagSchemeNameType]];
  tagger.string = text;
  NSMutableArray *found = [NSMutableArray array];
  __block NSUInteger total = 0;
  NSArray<NLTag> *wanted = @[NLTagPersonalName, NLTagPlaceName, NLTagOrganizationName];
  [tagger enumerateTagsInRange:NSMakeRange(0, text.length)
                          unit:NLTokenUnitWord
                        scheme:NLTagSchemeNameType
                       options:(NLTaggerOmitPunctuation | NLTaggerOmitWhitespace | NLTaggerJoinNames)
                    usingBlock:^(NLTag tag, NSRange range, BOOL *stop) {
    if (tag == nil || ![wanted containsObject:tag]) return;
    total += 1;
    if (found.count < kMaxItems) {
      [found addObject:@{@"text": [text substringWithRange:range], @"type": tag}];
    }
  }];
  reply(@{@"entities": found, @"total": @(total), @"truncated": @((BOOL)(total > found.count))}, nil);
}

/// Rank `candidates` by how close their meaning is to `text`.
///
/// The whole point of this capability. The caller sends a query and a list of
/// strings — file names, note titles, message subjects — and gets back the few
/// that actually match, without a model reading any of them and without one
/// byte leaving the phone. `grep` cannot do this (it matches letters) and the
/// model cannot do it at this size (it would have to read everything).
static void similar(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSString *text = text_arg(args, &error);
  if (text == nil) { reply(nil, error); return; }

  NSArray *candidates = args[@"candidates"];
  if (![candidates isKindOfClass:NSArray.class] || candidates.count == 0) {
    reply(nil, @"similar needs a non-empty 'candidates' array of strings to rank");
    return;
  }
  if (candidates.count > kMaxCandidates) {
    reply(nil, [NSString stringWithFormat:
                @"'candidates' has %lu entries; the limit is %lu. Rank them in batches and keep the "
                 "best of each.", (unsigned long)candidates.count, (unsigned long)kMaxCandidates]);
    return;
  }

  // Detect the language from the query AND the candidates together. A query is
  // often three words ("travel expenses"), and three words is not enough to
  // identify a language — "dog" is read as Danish. Guessing wrong silently
  // selects a different embedding, or none, so the guess is made from all the
  // text there is.
  NSString *requested = args[@"language"];
  NLLanguage language = nil;
  if ([requested isKindOfClass:NSString.class] && requested.length > 0) {
    language = requested;
  } else {
    NSMutableString *sample = [NSMutableString stringWithString:text];
    for (id entry in candidates) {
      if (![entry isKindOfClass:NSString.class]) continue;
      [sample appendString:@"\n"];
      [sample appendString:entry];
      if (sample.length > 4000) break;
    }
    language = dominant_language(sample);
  }
  if (language == nil) {
    reply(nil, @"could not tell what language the query is in; pass 'language' as a BCP-47 code");
    return;
  }
  NLEmbedding *embedding = [NLEmbedding sentenceEmbeddingForLanguage:language];
  if (embedding == nil) {
    // Only some languages ship a sentence embedding. Naming the language makes
    // this a fact the agent can relay rather than a mystery failure.
    reply(nil, [NSString stringWithFormat:
                @"this device has no sentence embedding for '%@', so meaning cannot be compared in "
                 "that language. Match words instead.", language]);
    return;
  }

  NSMutableArray *scored = [NSMutableArray array];
  for (NSUInteger i = 0; i < candidates.count; i++) {
    id entry = candidates[i];
    if (![entry isKindOfClass:NSString.class]) continue;
    NSString *candidate = entry;
    if (candidate.length == 0) continue;
    if (candidate.length > kMaxCandidateLength) {
      candidate = [candidate substringToIndex:kMaxCandidateLength];
    }
    NLDistance distance = [embedding distanceBetweenString:text andString:candidate
                                              distanceType:NLDistanceTypeCosine];
    // The number is kept, but it is called `cosine` and not `score`, because it
    // is not a relevance score and must not be read as one. Measured on device,
    // a correct best match scores 0.10 while an identical string scores 1.00 and
    // an unrelated one scores -0.32: the ORDER is meaningful, the magnitude is
    // not. A caller told "0.10" would throw away a right answer.
    [scored addObject:@{@"index": @(i),
                        @"text": entry,
                        @"cosine": @(1.0 - distance)}];
  }
  if (scored.count == 0) {
    reply(nil, @"'candidates' held no non-empty strings");
    return;
  }

  [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [b[@"cosine"] compare:a[@"cosine"]];
  }];
  NSNumber *limit = args[@"limit"];
  NSUInteger wanted = ([limit isKindOfClass:NSNumber.class] && limit.unsignedIntegerValue > 0)
                      ? limit.unsignedIntegerValue : 10;
  NSArray *best = scored.count > wanted ? [scored subarrayWithRange:NSMakeRange(0, wanted)] : scored;
  // Rank is what the caller should act on, so it is handed over explicitly
  // rather than left implicit in the array order.
  NSMutableArray *ranked = [NSMutableArray arrayWithCapacity:best.count];
  for (NSUInteger i = 0; i < best.count; i++) {
    NSMutableDictionary *row = [best[i] mutableCopy];
    row[@"rank"] = @(i + 1);
    [ranked addObject:row];
  }
  reply(@{@"matches": ranked,
          @"language": language,
          @"compared": @(scored.count),
          @"truncated": @((BOOL)(scored.count > best.count))}, nil);
}

void dsh_native_nlp(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"language"]) { identify_language(args, reply); return; }
  if ([op isEqualToString:@"entities"]) { named_entities(args, reply); return; }
  if ([op isEqualToString:@"similar"]) { similar(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"nlp has no operation '%@'", op]);
}
