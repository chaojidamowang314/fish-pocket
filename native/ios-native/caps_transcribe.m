// transcribe: what is said in an audio file that already exists on disk.
//
// **Why there is only the file half, when the same framework also does live
// dictation.** Speaking into a microphone is the *app's own interface*: the user
// holds a button next to the input field, watches the recording indicator, and
// sees words appear as they talk. They are present for every second of it. An
// agent answering inside a chat turn has neither the audio stream nor the
// occasion — nobody is talking to it live, and there is no screen of its own for
// an indicator to appear on. "What is said in this voice memo" is the real agent
// task, and it is the same shape as `vision.text` reading the words out of a
// picture: a file the caller already has, turned into text without shipping the
// bytes to a model. The reference implementation (OpenMinis,
// docs/native-services.md §9) puts both halves in one `apple-speech`; only this
// half belongs here.
//
// **So there is no AVAudioEngine in this file, no recording, and no microphone
// permission.** It needs `NSSpeechRecognitionUsageDescription` and nothing else.
// That is worth defending rather than noting: the day this file grows an audio
// engine it stops meaning "read this recording" and starts meaning "listen",
// which is a different promise to the user and a different permission to ask
// them for.
//
// Like vision, the one argument that can point somewhere the caller was never
// meant to reach is the path, so every path goes through `dsh_root_real` — the
// engine's own filesystem view. This reaches exactly the files a plugin could
// already open with `fs`, and widens nothing.
#import "dsh_ios_native.h"
#import "root.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

/// Segments are per word, so a ten-minute recording is well over a thousand of
/// them. This bounds the size of the reply and nothing else: it is not a view
/// about which words matter, and `text` is never cut by it (see
/// `segmentsTruncated`).
static const NSUInteger kMaxSegments = 2000;

/// Apple returns several candidate transcriptions for the same audio; this caps
/// how many of the others travel back whole, not which of them is any good.
static const NSUInteger kMaxAlternatives = 4;

/// Longer recordings are refused rather than half-transcribed, because there is
/// no half: transcribing part of a file would mean rewriting the audio first.
/// The refusal names the limit so the caller can split the file itself.
static const NSTimeInterval kMaxSeconds = 10 * 60;

/// Every wait on this bridge has to end in an answer. An unsettled promise
/// leaves the caller stopped on `await` with nothing to tell the user, which is
/// worse than any error (§4.3.2) — and a recogniser that never calls back is a
/// real outcome, not a hypothetical one. Recognition normally runs faster than
/// real time, so the deadline is the recording's own length plus this. It is a
/// backstop, not a performance promise.
static const NSTimeInterval kWaitFloorSeconds = 60;

static NSString *const kDeniedMessage =
    @"speech recognition is turned off for this app; the user can turn it on in Settings > Privacy "
     "& Security > Speech Recognition";

/// `Restricted` is not this user saying no. The device does not allow speech
/// recognition at all — Screen Time, or a configuration profile — and no switch
/// in this app can change that, so the agent should not send them looking for one.
static NSString *const kRestrictedMessage =
    @"this device does not allow speech recognition at all: it is restricted by Screen Time or by a "
     "configuration profile, which neither this app nor the user can change from here";

/// The not-asked-yet refusal; same shape and same reasoning as the one in
/// caps_notify.m — it describes where the switch is instead of quoting the
/// screen's title, because this file is not translated and the screen is.
static NSString *const kNotEnabledMessage =
    @"the user has not switched speech recognition on for this app yet. Nothing was transcribed. "
     "Tell them they can turn it on themselves under Device capabilities, which is in the app's "
     "sidebar — only they can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// Reading an audio file's header is I/O, and Node's thread is the one thread
/// that must not block on it. The recognition itself needs no queue of its own:
/// it runs in Apple's process and calls back, which is the one way this differs
/// from caps_vision.m, where the analysis is seconds of CPU right here.
static dispatch_queue_t transcribe_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.transcribe",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

/// Recognitions in flight. Nothing else is documented to retain an
/// `SFSpeechRecognitionTask`, and a released one stops — the same reason
/// caps_location.m holds its one-shot manager. Only touched on the main thread,
/// which is where tasks are started and where every settle lands.
static NSMutableArray<SFSpeechRecognitionTask *> *sInFlight;

/// Why this never calls `requestAuthorization:`: that call *is* the dialog, so
/// asking here would let whichever plugin transcribed first raise a system
/// prompt at a moment the user was not looking (§5.5). Returns nil when the
/// capability may run, or a sentence the agent can read out.
static NSString *authorization_refusal(void) {
  switch ([SFSpeechRecognizer authorizationStatus]) {
    case SFSpeechRecognizerAuthorizationStatusAuthorized:
      return nil;
    case SFSpeechRecognizerAuthorizationStatusDenied:
      return kDeniedMessage;
    case SFSpeechRecognizerAuthorizationStatusRestricted:
      return kRestrictedMessage;
    case SFSpeechRecognizerAuthorizationStatusNotDetermined:
    default:
      return kNotEnabledMessage;
  }
}

void DshTranscribeGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  // Already answered, either way: report that answer rather than calling into
  // iOS again, which would not re-ask anyway. A denial names Settings, because
  // after iOS's one question that is the only way back.
  SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
  if (status != SFSpeechRecognizerAuthorizationStatusNotDetermined) {
    BOOL granted = status == SFSpeechRecognizerAuthorizationStatusAuthorized;
    NSString *error = granted ? nil
                     : (status == SFSpeechRecognizerAuthorizationStatusRestricted ? kRestrictedMessage
                                                                                  : kDeniedMessage);
    done(granted, error);
    return;
  }
  [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus answer) {
    if (answer == SFSpeechRecognizerAuthorizationStatusRestricted) {
      done(NO, kRestrictedMessage);
      return;
    }
    // A plain "no" to the dialog carries no message: the wording for that
    // belongs to the screen, which is translated, and not to this file, which
    // is not (DshNativeCapabilities.h).
    done(answer == SFSpeechRecognizerAuthorizationStatusAuthorized, nil);
  }];
}

/// The real file an engine path names, or nil with the same refusal vision gives
/// — one sentence for one boundary, so a caller that hit it in one capability
/// recognises it in the other.
static NSURL *resolve_audio_url(NSString *path, NSString **error) {
  if (![path isKindOfClass:NSString.class] || path.length == 0) {
    *error = @"this operation needs a 'path' to an audio file";
    return nil;
  }
  char real[4096];
  if (dsh_root_real(path.fileSystemRepresentation, real, sizeof(real)) != 0) {
    *error = [NSString stringWithFormat:@"'%@' is not a path this app can reach", path];
    return nil;
  }
  return [NSURL fileURLWithPath:@(real)];
}

/// The recording's length in seconds, or 0 when nothing here can tell.
///
/// Only used to bound the work and to fill the audit line. `AVAudioFile` opens
/// what Core Audio can read, which is not everything the recogniser accepts, so
/// a failure here is deliberately *not* a refusal — deciding what counts as
/// audio is Apple's job, not ours (§4.5), and it reports its own error if the
/// file is not audio at all. The honest cost is that an unreadable header means
/// the length cap does not apply to that file.
static NSTimeInterval audio_seconds(NSURL *url) {
  AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:NULL];
  if (file == nil) return 0;
  double rate = file.processingFormat.sampleRate;
  if (rate <= 0) return 0;
  return (NSTimeInterval)file.length / rate;
}

/// Everything the caller gets back about one finished recognition.
///
/// `text` is Apple's own `bestTranscription` and is labelled as such: the
/// recogniser hands back several candidates for the same audio, and quietly
/// presenting one of them as *the* answer is exactly the kind of choosing that
/// is not ours to make (§4.5). So the others travel too, whole, with
/// `alternativeCount` saying how many there were in all. Nothing here re-ranks
/// them; the model can read two readings of the same sentence and tell which one
/// the rest of the conversation agrees with, which this function cannot.
static NSDictionary *result_json(SFSpeechRecognitionResult *result, NSString *locale,
                                 BOOL onDevice, NSTimeInterval seconds) {
  SFTranscription *best = result.bestTranscription;
  NSMutableArray *segments = [NSMutableArray array];
  for (SFTranscriptionSegment *segment in best.segments) {
    if (segments.count >= kMaxSegments) break;
    [segments addObject:@{@"text": segment.substring ?: @"",
                          @"start": @(segment.timestamp),
                          @"duration": @(segment.duration),
                          // Forwarded as Apple reports it, including the zeroes
                          // it reports for some engines: a confidence we made up
                          // would read exactly like one it measured.
                          @"confidence": @(segment.confidence)}];
  }

  NSMutableArray *alternatives = [NSMutableArray array];
  for (SFTranscription *candidate in result.transcriptions) {
    if (candidate == best) continue;
    if (alternatives.count >= kMaxAlternatives) break;
    if (candidate.formattedString.length > 0) [alternatives addObject:candidate.formattedString];
  }

  NSMutableDictionary *json = [@{
    @"text": best.formattedString ?: @"",
    @"segments": segments,
    @"segmentTotal": @(best.segments.count),
    // Named for the segments rather than `truncated`, because `text` is always
    // the whole transcript — only the per-word list is capped, and a caller that
    // read `truncated` as "the transcript is cut" would be wrong.
    @"segmentsTruncated": @((BOOL)(best.segments.count > segments.count)),
    @"alternatives": alternatives,
    @"alternativeCount": @(result.transcriptions.count),
    @"language": locale ?: @"",
    // The one field the model is meant to repeat out loud when it is false: the
    // recording went to Apple's servers. See `transcribe_file`.
    @"onDevice": @(onDevice),
  } mutableCopy];
  if (seconds > 0) json[@"seconds"] = @(seconds);

  // Length and word count, and nothing that was said. The audit list is shown
  // to the user, and copying the contents of a recording into a second place is
  // precisely what that list should not do (§5.4). The shape follows the other
  // capabilities: values joined with `·`, no words, because this file is not
  // translated and the line is rendered by Swift.
  json[@"auditSummary"] = seconds > 0
    ? [NSString stringWithFormat:@"%.0fs · %lu", seconds, (unsigned long)best.segments.count]
    : [NSString stringWithFormat:@"· %lu", (unsigned long)best.segments.count];
  return json;
}

static void transcribe_file(NSDictionary *args, DshNativeReply reply) {
  NSString *pathError = nil;
  NSURL *unresolved = resolve_audio_url(args[@"path"], &pathError);
  if (unresolved == nil) { reply(nil, pathError); return; }

  NSString *refusal = authorization_refusal();
  if (refusal != nil) { reply(nil, refusal); return; }

  NSString *language = args[@"language"];
  BOOL hasLanguage = [language isKindOfClass:NSString.class] && language.length > 0;

  // **Why `requiresOnDeviceRecognition` defaults to YES.**
  //
  // With it off, the recogniser uploads the audio to Apple's servers. That is a
  // sentence about the user's recording leaving their phone, and the user is
  // nowhere in this call to hear it: they asked what is in a voice memo, not for
  // the memo to be sent anywhere. A default that quietly ships someone's
  // recording off the device is the wrong default even though the server
  // understands more languages and sometimes understands them better — being
  // better is not the same as being the user's choice.
  //
  // The caller can say `onDevice: false` and get the server. Then the reply
  // carries `onDevice: false`, so the model has the fact in hand and can say it
  // in words. The cost of the default is real and accepted: on-device models are
  // per language and not every language has one here, so some recordings are
  // refused below that the server would have transcribed. Refused — not silently
  // uploaded, which is the whole point: the case where the upload matters most
  // is exactly the case where a fallback would perform it with nobody told.
  NSNumber *wanted = args[@"onDevice"];
  BOOL onDevice = ![wanted isKindOfClass:NSNumber.class] || wanted.boolValue;

  // Apple's own default is the language the phone is set to, and choosing that
  // for a caller who passed none is the one-off kind of default §4.5 keeps.
  SFSpeechRecognizer *recognizer =
    hasLanguage ? [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:language]]
                : [[SFSpeechRecognizer alloc] init];
  if (recognizer == nil) {
    reply(nil, hasLanguage
          ? [NSString stringWithFormat:@"this device cannot recognise '%@'; the 'languages' operation "
                                        "lists the ones it can", language]
          : @"this device has no speech recognition for the language it is set to; pass 'language' "
             "with one of the codes the 'languages' operation lists");
    return;
  }
  NSString *locale = recognizer.locale.localeIdentifier;

  if (onDevice && !recognizer.supportsOnDeviceRecognition) {
    reply(nil, [NSString stringWithFormat:
                @"'%@' can only be recognised by Apple's servers on this device — there is no "
                 "on-device model installed for it, so transcribing this recording would upload it. "
                 "Nothing was uploaded and nothing was transcribed. Pass 'onDevice' false to go "
                 "ahead over the network, and tell the user first that the recording will be sent "
                 "to Apple.", locale]);
    return;
  }

  // `isAvailable` is deliberately not checked. It is filled in asynchronously
  // after the recogniser connects, so reading it here answers NO on devices that
  // work perfectly a moment later — a refusal we would have invented. If the
  // service really is away, Apple says so in the error below.
  dispatch_async(transcribe_queue(), ^{
    NSTimeInterval seconds = audio_seconds(unresolved);
    if (seconds > kMaxSeconds) {
      reply(nil, [NSString stringWithFormat:
                  @"that recording is %.0f minutes long and this transcribes at most %.0f minutes at "
                   "a time. Nothing was transcribed; split the file and transcribe the parts.",
                  seconds / 60, kMaxSeconds / 60]);
      return;
    }

    SFSpeechURLRecognitionRequest *request =
      [[SFSpeechURLRecognitionRequest alloc] initWithURL:unresolved];
    request.requiresOnDeviceRecognition = onDevice;
    // One answer, not a stream. Partial results would mean deciding when the
    // transcript is good enough to stop, and that judgement is not ours (§4.5).
    request.shouldReportPartialResults = NO;
    // What the audio is, not what the answer should say: a recording of someone
    // talking is continuous speech, not a search query or a yes/no confirmation.
    request.taskHint = SFSpeechRecognitionTaskHintDictation;
    // Apple's own switch, and the caller can turn it off. Default on because
    // without it the transcript is a wall of words with no sentence boundaries,
    // which is harder to read for a person and for a model.
    NSNumber *punctuation = args[@"punctuation"];
    request.addsPunctuation = ![punctuation isKindOfClass:NSNumber.class] || punctuation.boolValue;

    dsh_native_on_main(^{
      if (sInFlight == nil) sInFlight = [NSMutableArray array];
      __block BOOL settled = NO;
      __block SFSpeechRecognitionTask *task = nil;

      // One reply, whatever arrives first: a final result, an error, or the
      // deadline. Assigning `task = nil` here is also what breaks the retain
      // cycle between the task and the blocks that hold it.
      void (^settle)(NSDictionary *, NSString *) = ^(NSDictionary *result, NSString *error) {
        if (settled) return;
        settled = YES;
        if (task != nil) {
          [sInFlight removeObject:task];
          // A no-op once it has finished; what stops it when the deadline won.
          [task cancel];
          task = nil;
        }
        reply(result, error);
      };

      task = [recognizer recognitionTaskWithRequest:request
                                      resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        // Apple may call this on any thread, and `settle` touches `sInFlight`.
        dsh_native_on_main(^{
          if (error != nil) {
            // Forwarded as Apple words it, with the one piece of context the
            // message itself never carries: which of the two paths just failed.
            // Not interpreted further — mapping its error codes to explanations
            // is a table we would be patching forever (§4.5).
            settle(nil, [NSString stringWithFormat:@"this recording could not be transcribed %@: %@",
                         onDevice ? @"on this device" : @"by Apple's servers",
                         error.localizedDescription ?: @"the recogniser gave no reason"]);
            return;
          }
          if (result == nil || !result.isFinal) return;
          // Reading the recogniser here also keeps it alive for as long as the
          // task holds this block, which Apple does not promise to do itself.
          settle(result_json(result, recognizer.locale.localeIdentifier, onDevice, seconds), nil);
        });
      }];

      if (task == nil) {
        settle(nil, @"iOS would not start a recognition for this file");
        return;
      }
      if (!settled) [sInFlight addObject:task];

      NSTimeInterval deadline = kWaitFloorSeconds + seconds;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        settle(nil, [NSString stringWithFormat:
                     @"the recogniser did not finish this recording within %.0f seconds and was "
                      "stopped. Nothing was transcribed.", deadline]);
      });
    });
  });
}

/// Which languages this device can recognise at all.
///
/// No authorisation check: this asks what the device can do, not anything about
/// the user, and it is the operation a caller reaches for *after* being refused
/// above — needing the grant first would make it useless there. It leaves no
/// audit entry for the same reason: nothing of the user's was touched (§5.4).
static void list_languages(DshNativeReply reply) {
  dsh_native_on_main(^{
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    for (NSLocale *locale in [SFSpeechRecognizer supportedLocales]) {
      [languages addObject:locale.localeIdentifier];
    }
    // `supportedLocales` is a set, so *some* order has to be imposed on it;
    // alphabetical is the one that says nothing about which language is better.
    [languages sortUsingSelector:@selector(compare:)];

    NSMutableDictionary *json = [@{@"languages": languages, @"total": @(languages.count)} mutableCopy];
    // Whether the common case — no 'language' argument — stays on the phone.
    // Per-language on-device support is not listed for all of them: that would
    // mean standing up a recogniser per locale, and `file` reports it exactly
    // where it matters, in the refusal.
    SFSpeechRecognizer *preferred = [[SFSpeechRecognizer alloc] init];
    if (preferred != nil) {
      json[@"default"] = preferred.locale.localeIdentifier;
      json[@"defaultSupportsOnDevice"] = @(preferred.supportsOnDeviceRecognition);
    }
    reply(json, nil);
  });
}

void dsh_native_transcribe(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"file"]) { transcribe_file(args, reply); return; }
  if ([op isEqualToString:@"languages"]) { list_languages(reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"transcribe has no operation '%@'", op]);
}
