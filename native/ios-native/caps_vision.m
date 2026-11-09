// vision: read what is in an image — text, barcodes, what it is a picture of,
// how many faces. All on device, no network, no permission.
//
// **Why this needs no permission and still has a boundary.** Vision analyses an
// image the caller already has; it reaches no camera and no photo library. But
// it takes a *path*, and a path is the one argument that can point somewhere
// the caller was never meant to reach. So every path goes through
// `dsh_root_real` — the engine's own filesystem view — which confines this to
// exactly the files a plugin could already open with `fs`. It widens nothing;
// it only saves the caller from shipping the bytes to a model.
//
// Faces are counted and boxed, never identified: there is no recognition here
// and none is planned. "How many people are in this photo" is a different
// question from "who", and only the first one is answered.
#import "dsh_ios_native.h"
#import "root.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>

static const NSUInteger kMaxItems = 200;

/// Vision is CPU-bound and can take seconds on a large image. Node's thread must
/// not wait on it and the main thread must not either.
static dispatch_queue_t vision_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.vision",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

/// Load the image an engine path names, or nil with a reason the agent can read.
static CGImageRef copy_image(NSString *path, NSString **error) CF_RETURNS_RETAINED {
  if (![path isKindOfClass:NSString.class] || path.length == 0) {
    *error = @"this operation needs a 'path' to an image file";
    return NULL;
  }
  char real[4096];
  if (dsh_root_real(path.fileSystemRepresentation, real, sizeof(real)) != 0) {
    *error = [NSString stringWithFormat:@"'%@' is not a path this app can reach", path];
    return NULL;
  }
  NSURL *url = [NSURL fileURLWithPath:@(real)];
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (source == NULL) {
    *error = [NSString stringWithFormat:@"'%@' could not be opened as an image", path];
    return NULL;
  }
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  if (image == NULL) {
    *error = [NSString stringWithFormat:@"'%@' is not an image this device can read", path];
    return NULL;
  }
  return image;
}

/// Run `requests` over the image at `path` and hand the results to `next`.
static void with_vision(NSString *path, DshNativeReply reply,
                        NSArray<VNRequest *> *requests, void (^next)(void)) {
  NSString *error = nil;
  CGImageRef image = copy_image(path, &error);
  if (image == NULL) { reply(nil, error); return; }

  dispatch_async(vision_queue(), ^{
    VNImageRequestHandler *handler =
      [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *runError = nil;
    BOOL ok = [handler performRequests:requests error:&runError];
    CGImageRelease(image);
    if (!ok) {
      reply(nil, runError.localizedDescription ?: @"the image could not be analysed");
      return;
    }
    next();
  });
}

/// A normalised Vision box as the pixel-free rectangle callers can reason about.
static NSDictionary *box_json(CGRect box) {
  return @{@"x": @(box.origin.x), @"y": @(box.origin.y),
           @"width": @(box.size.width), @"height": @(box.size.height)};
}

static void recognize_text(NSDictionary *args, DshNativeReply reply) {
  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
  request.recognitionLevel = [args[@"level"] isEqualToString:@"fast"]
                             ? VNRequestTextRecognitionLevelFast
                             : VNRequestTextRecognitionLevelAccurate;
  // Without this the default is English only, and a Chinese receipt comes back
  // as a handful of mangled Latin letters rather than as an obvious failure.
  NSArray *languages = args[@"languages"];
  request.recognitionLanguages = [languages isKindOfClass:NSArray.class] && languages.count > 0
                                 ? languages : @[@"zh-Hans", @"zh-Hant", @"en-US"];
  request.usesLanguageCorrection = YES;

  with_vision(args[@"path"], reply, @[request], ^{
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableArray *text = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
      if (lines.count >= kMaxItems) break;
      VNRecognizedText *best = [observation topCandidates:1].firstObject;
      if (best.string.length == 0) continue;
      [text addObject:best.string];
      [lines addObject:@{@"text": best.string,
                         @"confidence": @(best.confidence),
                         @"box": box_json(observation.boundingBox)}];
    }
    reply(@{@"text": [text componentsJoinedByString:@"\n"],
            @"lines": lines,
            @"total": @(request.results.count),
            @"truncated": @((BOOL)(request.results.count > lines.count))}, nil);
  });
}

static void detect_barcodes(NSDictionary *args, DshNativeReply reply) {
  VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
  with_vision(args[@"path"], reply, @[request], ^{
    NSMutableArray *codes = [NSMutableArray array];
    for (VNBarcodeObservation *observation in request.results) {
      if (codes.count >= kMaxItems) break;
      [codes addObject:@{@"payload": observation.payloadStringValue ?: @"",
                         @"symbology": observation.symbology,
                         @"box": box_json(observation.boundingBox)}];
    }
    reply(@{@"codes": codes}, nil);
  });
}

static void classify(NSDictionary *args, DshNativeReply reply) {
  VNClassifyImageRequest *request = [[VNClassifyImageRequest alloc] init];
  with_vision(args[@"path"], reply, @[request], ^{
    // Vision returns a long tail of near-zero scores. A threshold keeps the
    // answer to the part that means anything; the default is deliberately
    // generous rather than clever.
    NSNumber *minimum = args[@"minimumConfidence"];
    float floor = [minimum isKindOfClass:NSNumber.class] ? minimum.floatValue : 0.1f;
    NSMutableArray *labels = [NSMutableArray array];
    for (VNClassificationObservation *observation in request.results) {
      if (labels.count >= 20) break;
      if (observation.confidence < floor) continue;
      [labels addObject:@{@"label": observation.identifier, @"confidence": @(observation.confidence)}];
    }
    reply(@{@"labels": labels}, nil);
  });
}

static void detect_faces(NSDictionary *args, DshNativeReply reply) {
  VNDetectFaceRectanglesRequest *request = [[VNDetectFaceRectanglesRequest alloc] init];
  with_vision(args[@"path"], reply, @[request], ^{
    NSMutableArray *faces = [NSMutableArray array];
    for (VNFaceObservation *observation in request.results) {
      if (faces.count >= kMaxItems) break;
      [faces addObject:@{@"box": box_json(observation.boundingBox)}];
    }
    // Count and position only. Nothing here says who anyone is.
    reply(@{@"faces": faces, @"count": @(faces.count)}, nil);
  });
}

void dsh_native_vision(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"text"]) { recognize_text(args, reply); return; }
  if ([op isEqualToString:@"barcodes"]) { detect_barcodes(args, reply); return; }
  if ([op isEqualToString:@"classify"]) { classify(args, reply); return; }
  if ([op isEqualToString:@"faces"]) { detect_faces(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"vision has no operation '%@'", op]);
}
