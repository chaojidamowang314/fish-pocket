// speak: read text out loud. No permission, no network, nothing stored — the
// system voices, on device.
//
// `say` returns as soon as the utterance is queued rather than when it finishes
// speaking: the agent should not be blocked for the length of a paragraph, and
// a turn that ends while audio plays is fine (the app keeps an audio background
// mode for exactly this kind of thing).
#import "dsh_ios_native.h"
#import <AVFoundation/AVFoundation.h>

/// One synthesiser for the process, so `stop` can reach what `say` started.
static AVSpeechSynthesizer *synthesizer(void) {
  static AVSpeechSynthesizer *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [AVSpeechSynthesizer new]; });
  return shared;
}

static void say(NSDictionary *args, DshNativeReply reply) {
  NSString *text = args[@"text"];
  if (![text isKindOfClass:NSString.class] || text.length == 0) {
    reply(nil, @"say needs a non-empty 'text'");
    return;
  }

  AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
  // An explicit language keeps a Chinese sentence from being read by an English
  // voice; without one AVFoundation picks by the device locale, which is right
  // often enough to be the default.
  NSString *language = args[@"language"];
  if ([language isKindOfClass:NSString.class] && language.length > 0) {
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:language];
    if (voice == nil) {
      reply(nil, [NSString stringWithFormat:@"no installed voice for '%@'", language]);
      return;
    }
    utterance.voice = voice;
  }
  NSNumber *rate = args[@"rate"];
  if ([rate isKindOfClass:NSNumber.class]) {
    utterance.rate = fmaxf(AVSpeechUtteranceMinimumSpeechRate,
                           fminf(AVSpeechUtteranceMaximumSpeechRate, rate.floatValue));
  }

  dsh_native_on_main(^{ [synthesizer() speakUtterance:utterance]; });
  reply(@{@"speaking": @YES, @"characters": @(text.length)}, nil);
}

static void stop(DshNativeReply reply) {
  dsh_native_on_main(^{ [synthesizer() stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; });
  reply(@{@"stopped": @YES}, nil);
}

void dsh_native_speak(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"say"]) {
    say(args, reply);
  } else {
    stop(reply);
  }
}
