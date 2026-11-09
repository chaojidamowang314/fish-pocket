// nlp: the NaturalLanguage framework. Language identification, tokenising,
// parts of speech, named entities and sentiment — all on device, no network,
// no permission, nothing stored.
//
// Why give a language model a language toolkit: these answer cheaply and
// exactly where a model answers expensively and approximately. "Which language
// is this file in" over a thousand files is a loop here and a thousand requests
// otherwise, and the answer does not leave the phone.
#import "dsh_ios_native.h"
#import <NaturalLanguage/NaturalLanguage.h>

/// Long inputs are the point (that is when running locally beats asking the
/// model), but an unbounded string crossing the N-API boundary and back is not.
static const NSUInteger kMaxTextLength = 200000;
/// Per-request cap on how many tokens or entities come back. A tokenised novel
/// helps nobody and would bury the useful answer.
static const NSUInteger kMaxItems = 2000;

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

static void identify_language(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSString *text = text_arg(args, &error);
  if (text == nil) { reply(nil, error); return; }

  NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
  [recognizer processString:text];
  NSDictionary<NLLanguage, NSNumber *> *hypotheses = [recognizer languageHypothesesWithMaximum:5];
  NSMutableArray *ranked = [NSMutableArray array];
  NSArray *sorted = [hypotheses.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [hypotheses[b] compare:hypotheses[a]];
  }];
  for (NLLanguage language in sorted) {
    [ranked addObject:@{@"language": language, @"confidence": hypotheses[language]}];
  }
  // `dominantLanguage` can be nil for a string with nothing to go on (digits,
  // emoji). Saying so is more useful than guessing.
  reply(@{@"language": recognizer.dominantLanguage ?: NSNull.null,
          @"hypotheses": ranked}, nil);
}

/// `unit` picks what a "token" is: word, sentence or paragraph.
static NLTokenUnit token_unit(NSDictionary *args) {
  NSString *unit = args[@"unit"];
  if ([unit isEqualToString:@"sentence"]) return NLTokenUnitSentence;
  if ([unit isEqualToString:@"paragraph"]) return NLTokenUnitParagraph;
  return NLTokenUnitWord;
}

static void tokenize(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSString *text = text_arg(args, &error);
  if (text == nil) { reply(nil, error); return; }

  NLTokenizer *tokenizer = [[NLTokenizer alloc] initWithUnit:token_unit(args)];
  tokenizer.string = text;
  NSMutableArray<NSString *> *tokens = [NSMutableArray array];
  __block NSUInteger total = 0;
  [tokenizer enumerateTokensInRange:NSMakeRange(0, text.length)
                         usingBlock:^(NSRange range, NLTokenizerAttributes attrs, BOOL *stop) {
    total += 1;
    if (tokens.count < kMaxItems) [tokens addObject:[text substringWithRange:range]];
  }];
  reply(@{@"tokens": tokens, @"total": @(total), @"truncated": @((BOOL)(total > tokens.count))}, nil);
}

static void sentiment(NSDictionary *args, DshNativeReply reply) {
  NSString *error = nil;
  NSString *text = text_arg(args, &error);
  if (text == nil) { reply(nil, error); return; }

  NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[NLTagSchemeSentimentScore]];
  tagger.string = text;
  NLTag score = [tagger tagAtIndex:0 unit:NLTokenUnitParagraph
                            scheme:NLTagSchemeSentimentScore tokenRange:NULL];
  if (score == nil) {
    reply(nil, @"this language has no sentiment model on this device");
    return;
  }
  // -1 … 1. Handed over as the number it is rather than as "positive" or
  // "negative": where the line falls is the caller's judgement, not ours.
  reply(@{@"score": @(score.doubleValue)}, nil);
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

void dsh_native_nlp(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"language"]) { identify_language(args, reply); return; }
  if ([op isEqualToString:@"tokenize"]) { tokenize(args, reply); return; }
  if ([op isEqualToString:@"sentiment"]) { sentiment(args, reply); return; }
  if ([op isEqualToString:@"entities"]) { named_entities(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"nlp has no operation '%@'", op]);
}
