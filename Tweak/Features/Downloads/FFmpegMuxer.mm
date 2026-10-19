#import "FFmpegMuxer.h"
#import <copyfile.h>

#define AVMediaType YTKACEFFmpegMediaType
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libavutil/hwcontext.h>
}
#undef AVMediaType

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "DownloadLog.h"

static NSString *YTKACEFFmpegMessage(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buffer, sizeof(buffer));
    return [NSString stringWithUTF8String:buffer] ?: @"FFmpeg failed";
}

static NSError *YTKACEFFmpegError(int code, NSString *stage) {
    NSString *message = [NSString stringWithFormat:@"%@: %@", stage,
        YTKACEFFmpegMessage(code)];
    return [NSError errorWithDomain:@"YTKACEFFmpeg" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static int YTKACEOpenInput(NSURL *URL, enum YTKACEFFmpegMediaType type,
                           AVFormatContext **context, int *streamIndex) {
    int result = avformat_open_input(context, URL.fileSystemRepresentation,
        NULL, NULL);
    if (result < 0) return result;
    result = avformat_find_stream_info(*context, NULL);
    if (result < 0) return result;
    result = av_find_best_stream(*context, type, -1, -1, NULL, 0);
    if (result < 0) return result;
    *streamIndex = result;
    return 0;
}

static int YTKACEReadPacket(AVFormatContext *context, int streamIndex,
                            AVPacket *packet) {
    int result = 0;
    while ((result = av_read_frame(context, packet)) >= 0) {
        if (packet->stream_index == streamIndex) return 0;
        av_packet_unref(packet);
    }
    return result;
}

static int64_t YTKACEPacketTime(AVPacket *packet, AVStream *stream) {
    int64_t value = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    return value == AV_NOPTS_VALUE ? INT64_MAX :
        av_rescale_q(value, stream->time_base, AV_TIME_BASE_Q);
}

static int YTKACEWritePacket(AVFormatContext *output, AVPacket *packet,
                             AVStream *inputStream, AVStream *outputStream) {
    av_packet_rescale_ts(packet, inputStream->time_base, outputStream->time_base);
    packet->stream_index = outputStream->index;
    packet->pos = -1;
    int result = av_interleaved_write_frame(output, packet);
    av_packet_unref(packet);
    return result;
}

static NSError *YTKACERemux(NSURL *videoURL, NSURL *audioURL,
                            NSURL *outputURL) {
    AVFormatContext *video = NULL;
    AVFormatContext *audio = NULL;
    AVFormatContext *output = NULL;
    AVPacket *videoPacket = NULL;
    AVPacket *audioPacket = NULL;
    AVStream *videoInput = NULL;
    AVStream *audioInput = NULL;
    AVStream *videoOutput = NULL;
    AVStream *audioOutput = NULL;
    AVDictionary *options = NULL;
    int videoIndex = -1;
    int audioIndex = -1;
    BOOL hasVideo = NO;
    BOOL hasAudio = NO;
    NSString *stage = @"Open video";
    int result = YTKACEOpenInput(videoURL, AVMEDIA_TYPE_VIDEO, &video, &videoIndex);
    if (result < 0) goto cleanup;
    result = YTKACEOpenInput(audioURL, AVMEDIA_TYPE_AUDIO, &audio, &audioIndex);
    stage = @"Open audio";
    if (result < 0) goto cleanup;
    result = avformat_alloc_output_context2(&output, NULL, "mp4",
        outputURL.fileSystemRepresentation);
    stage = @"Create output";
    if (result < 0 || output == NULL) {
        if (result >= 0) result = AVERROR_UNKNOWN;
        goto cleanup;
    }
    videoInput = video->streams[videoIndex];
    audioInput = audio->streams[audioIndex];
    videoOutput = avformat_new_stream(output, NULL);
    audioOutput = avformat_new_stream(output, NULL);
    stage = @"Create tracks";
    if (videoOutput == NULL || audioOutput == NULL) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    result = avcodec_parameters_copy(videoOutput->codecpar, videoInput->codecpar);
    if (result < 0) goto cleanup;
    result = avcodec_parameters_copy(audioOutput->codecpar, audioInput->codecpar);
    if (result < 0) goto cleanup;
    videoOutput->codecpar->codec_tag = 0;
    audioOutput->codecpar->codec_tag = 0;
    videoOutput->time_base = videoInput->time_base;
    audioOutput->time_base = audioInput->time_base;
    if ((output->oformat->flags & AVFMT_NOFILE) == 0) {
        result = avio_open(&output->pb, outputURL.fileSystemRepresentation,
            AVIO_FLAG_WRITE);
        stage = @"Open output";
        if (result < 0) goto cleanup;
    }
    av_dict_set(&options, "movflags", "+faststart", 0);
    result = avformat_write_header(output, &options);
    stage = @"Write header";
    if (result < 0) goto cleanup;

    videoPacket = av_packet_alloc();
    audioPacket = av_packet_alloc();
    if (videoPacket == NULL || audioPacket == NULL) {
        result = AVERROR(ENOMEM);
        stage = @"Create packets";
        goto cleanup;
    }
    hasVideo = YTKACEReadPacket(video, videoIndex, videoPacket) >= 0;
    hasAudio = YTKACEReadPacket(audio, audioIndex, audioPacket) >= 0;
    while (hasVideo || hasAudio) {
        BOOL writeVideo = hasVideo;
        if (hasVideo && hasAudio) {
            writeVideo = YTKACEPacketTime(videoPacket, videoInput) <=
                YTKACEPacketTime(audioPacket, audioInput);
        }
        if (writeVideo) {
            result = YTKACEWritePacket(output, videoPacket, videoInput, videoOutput);
            stage = @"Write video";
            if (result < 0) goto cleanup;
            hasVideo = YTKACEReadPacket(video, videoIndex, videoPacket) >= 0;
        } else {
            result = YTKACEWritePacket(output, audioPacket, audioInput, audioOutput);
            stage = @"Write audio";
            if (result < 0) goto cleanup;
            hasAudio = YTKACEReadPacket(audio, audioIndex, audioPacket) >= 0;
        }
    }
    result = av_write_trailer(output);
    stage = @"Write trailer";

cleanup:
    av_dict_free(&options);
    av_packet_free(&videoPacket);
    av_packet_free(&audioPacket);
    avformat_close_input(&video);
    avformat_close_input(&audio);
    if (output != NULL) {
        if (output->pb != NULL) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    return result < 0 ? YTKACEFFmpegError(result, stage) : nil;
}

static NSError *YTKACERemuxAudio(NSURL *audioURL, NSURL *outputURL) {
    AVFormatContext *audio = NULL;
    AVFormatContext *output = NULL;
    AVPacket *packet = NULL;
    AVStream *audioInput = NULL;
    AVStream *audioOutput = NULL;
    AVDictionary *options = NULL;
    int audioIndex = -1;
    NSString *stage = @"Open audio";
    int result = YTKACEOpenInput(audioURL, AVMEDIA_TYPE_AUDIO, &audio, &audioIndex);
    if (result < 0) goto cleanup;
    result = avformat_alloc_output_context2(&output, NULL, "mp4",
        outputURL.fileSystemRepresentation);
    stage = @"Create output";
    if (result < 0 || output == NULL) {
        if (result >= 0) result = AVERROR_UNKNOWN;
        goto cleanup;
    }
    audioInput = audio->streams[audioIndex];
    audioOutput = avformat_new_stream(output, NULL);
    stage = @"Create track";
    if (audioOutput == NULL) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    result = avcodec_parameters_copy(audioOutput->codecpar, audioInput->codecpar);
    if (result < 0) goto cleanup;
    audioOutput->codecpar->codec_tag = 0;
    audioOutput->time_base = audioInput->time_base;
    if ((output->oformat->flags & AVFMT_NOFILE) == 0) {
        result = avio_open(&output->pb, outputURL.fileSystemRepresentation,
            AVIO_FLAG_WRITE);
        stage = @"Open output";
        if (result < 0) goto cleanup;
    }
    av_dict_set(&options, "movflags", "+faststart", 0);
    result = avformat_write_header(output, &options);
    stage = @"Write header";
    if (result < 0) goto cleanup;
    packet = av_packet_alloc();
    if (packet == NULL) {
        result = AVERROR(ENOMEM);
        stage = @"Create packet";
        goto cleanup;
    }
    while ((result = YTKACEReadPacket(audio, audioIndex, packet)) >= 0) {
        result = YTKACEWritePacket(output, packet, audioInput, audioOutput);
        stage = @"Write audio";
        if (result < 0) goto cleanup;
    }
    if (result == AVERROR_EOF) result = 0;
    if (result < 0) goto cleanup;
    result = av_write_trailer(output);
    stage = @"Write trailer";

cleanup:
    av_dict_free(&options);
    av_packet_free(&packet);
    avformat_close_input(&audio);
    if (output != NULL) {
        if (output->pb != NULL) avio_closep(&output->pb);
        avformat_free_context(output);
    }
    return result < 0 ? YTKACEFFmpegError(result, stage) : nil;
}


// Conversions that are running, keyed by job identifier. The value turns to
// @YES when the user cancels; the conversion loops poll it and stop. Entries
// exist only while a conversion runs, so the table cannot grow without bound.
static NSMutableDictionary<NSString *, NSNumber *> *YTKACEConversionStates(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *states;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ states = [NSMutableDictionary dictionary]; });
    return states;
}

static void YTKACEBeginConversion(NSString *identifier) {
    if (identifier.length == 0) return;
    NSMutableDictionary<NSString *, NSNumber *> *states = YTKACEConversionStates();
    @synchronized (states) {
        states[identifier] = @NO;
    }
}

static BOOL YTKACEConversionCancelled(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSMutableDictionary<NSString *, NSNumber *> *states = YTKACEConversionStates();
    @synchronized (states) {
        return states[identifier].boolValue;
    }
}

static void YTKACEEndConversion(NSString *identifier) {
    if (identifier.length == 0) return;
    NSMutableDictionary<NSString *, NSNumber *> *states = YTKACEConversionStates();
    @synchronized (states) {
        [states removeObjectForKey:identifier];
    }
}

void YTKACEFFmpegCancelConversion(NSString *identifier) {
    if (identifier.length == 0) return;
    NSMutableDictionary<NSString *, NSNumber *> *states = YTKACEConversionStates();
    BOOL running = NO;
    @synchronized (states) {
        if (states[identifier] != nil) {
            states[identifier] = @YES;
            running = YES;
        }
    }
    YTKACEDownloadLog(@"convert", @"cancel requested %@ running=%d",
                      identifier, running);
}

static NSError *YTKACEConversionCancelledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError
        userInfo:@{NSLocalizedDescriptionKey: @"Conversion cancelled"}];
}

// Encodes and writes every packet the encoder has ready. Returns < 0 on a
// write failure; EAGAIN/EOF from the encoder are not failures.
static int YTKACEDrainEncoder(AVCodecContext *encoder, AVFormatContext *output,
                              AVStream *stream, AVPacket *encoded) {
    int result = 0;
    while ((result = avcodec_receive_packet(encoder, encoded)) >= 0) {
        encoded->stream_index = stream->index;
        av_packet_rescale_ts(encoded, encoder->time_base, stream->time_base);
        result = av_interleaved_write_frame(output, encoded);
        av_packet_unref(encoded);
        if (result < 0) return result;
    }
    return (result == AVERROR(EAGAIN) || result == AVERROR_EOF) ? 0 : result;
}

static NSError *YTKACEAudioToVideo(NSURL *audioURL, NSData *artwork,
                                   NSURL *outputURL, NSString *identifier,
                                   YTKACEFFmpegProgress progress) {
    NSString *artworkPath = nil;
    if (artwork.length != 0) {
        // Unique per job so concurrent conversions never share (or delete)
        // each other's artwork; the YTKACE- prefix lets the startup scratch
        // purge collect it if the app dies mid-conversion.
        artworkPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @"YTKACE-art-%@.jpg", NSUUID.UUID.UUIDString]];
        if (![artwork writeToFile:artworkPath atomically:YES]) artworkPath = nil;
    }
    AVFormatContext *audioInput = NULL;
    AVFormatContext *imageInput = NULL;
    AVFormatContext *output = NULL;
    AVCodecContext *imageDecoder = NULL;
    AVCodecContext *encoder = NULL;
    struct SwsContext *scaler = NULL;
    AVFrame *imageFrame = av_frame_alloc();
    AVFrame *videoFrame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    AVPacket *encoded = av_packet_alloc();
    NSError *error = nil;
    int audioIndex = -1;
    int status = 0;

    if (imageFrame == NULL || videoFrame == NULL || packet == NULL ||
        encoded == NULL) {
        error = YTKACEFFmpegError(AVERROR(ENOMEM), @"Could not convert");
        goto finish;
    }
    if (avformat_open_input(&audioInput, audioURL.path.UTF8String, NULL, NULL) < 0 ||
        avformat_find_stream_info(audioInput, NULL) < 0) {
        error = YTKACEFFmpegError(-1, @"Could not read the audio");
        goto finish;
    }
    for (unsigned int index = 0; index < audioInput->nb_streams; index++) {
        if (audioInput->streams[index]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audioIndex = (int)index;
            break;
        }
    }
    if (audioIndex < 0) {
        error = YTKACEFFmpegError(-1, @"No audio track");
        goto finish;
    }

    {
        const int width = 720;
        const int height = 720;
        avformat_alloc_output_context2(&output, NULL, "mp4",
                                       outputURL.path.UTF8String);
        if (output == NULL) {
            error = YTKACEFFmpegError(-1, @"Could not create the file");
            goto finish;
        }
        const AVCodec *encoderCodec =
            avcodec_find_encoder_by_name("h264_videotoolbox");
        if (encoderCodec == NULL) {
            error = YTKACEFFmpegError(-1, @"Conversion is unavailable");
            goto finish;
        }
        encoder = avcodec_alloc_context3(encoderCodec);
        if (encoder == NULL) {
            error = YTKACEFFmpegError(AVERROR(ENOMEM), @"Conversion is unavailable");
            goto finish;
        }
        encoder->width = width;
        encoder->height = height;
        encoder->pix_fmt = AV_PIX_FMT_NV12;
        encoder->time_base = (AVRational){1, 1};
        encoder->framerate = (AVRational){1, 1};
        encoder->bit_rate = 400000;
        if (output->oformat->flags & AVFMT_GLOBALHEADER) {
            encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        if (avcodec_open2(encoder, encoderCodec, NULL) < 0) {
            error = YTKACEFFmpegError(-1, @"Conversion is unavailable");
            goto finish;
        }
        AVStream *videoStream = avformat_new_stream(output, NULL);
        if (videoStream == NULL ||
            avcodec_parameters_from_context(videoStream->codecpar, encoder) < 0) {
            error = YTKACEFFmpegError(AVERROR(ENOMEM), @"Could not create the file");
            goto finish;
        }
        videoStream->codecpar->codec_tag = MKTAG('a', 'v', 'c', '1');
        videoStream->time_base = encoder->time_base;
        AVStream *audioStream = avformat_new_stream(output, NULL);
        if (audioStream == NULL ||
            avcodec_parameters_copy(audioStream->codecpar,
                                    audioInput->streams[audioIndex]->codecpar) < 0) {
            error = YTKACEFFmpegError(AVERROR(ENOMEM), @"Could not create the file");
            goto finish;
        }
        audioStream->codecpar->codec_tag = 0;

        if (!(output->oformat->flags & AVFMT_NOFILE)) {
            if (avio_open(&output->pb, outputURL.path.UTF8String,
                          AVIO_FLAG_WRITE) < 0) {
                error = YTKACEFFmpegError(-1, @"Could not create the file");
                goto finish;
            }
        }
        if (avformat_write_header(output, NULL) < 0) {
            error = YTKACEFFmpegError(-1, @"Could not create the file");
            goto finish;
        }

        videoFrame->format = AV_PIX_FMT_NV12;
        videoFrame->width = width;
        videoFrame->height = height;
        status = av_frame_get_buffer(videoFrame, 0);
        if (status < 0) {
            error = YTKACEFFmpegError(status, @"Could not convert");
            goto finish;
        }
        memset(videoFrame->data[0], 16, (size_t)videoFrame->linesize[0] * height);
        memset(videoFrame->data[1], 128,
               (size_t)videoFrame->linesize[1] * height / 2);

        YTKACEDownloadLog(@"convert", @"artwork bytes=%lu path=%@",
            (unsigned long)artwork.length, artworkPath ?: @"none");
        if (artworkPath != nil &&
            avformat_open_input(&imageInput, artworkPath.UTF8String, NULL, NULL) >= 0 &&
            avformat_find_stream_info(imageInput, NULL) >= 0 &&
            imageInput->nb_streams > 0) {
            const AVCodec *imageCodec =
                avcodec_find_decoder(imageInput->streams[0]->codecpar->codec_id);
            if (imageCodec != NULL) {
                imageDecoder = avcodec_alloc_context3(imageCodec);
                if (imageDecoder != NULL &&
                    avcodec_parameters_to_context(imageDecoder,
                        imageInput->streams[0]->codecpar) >= 0 &&
                    avcodec_open2(imageDecoder, imageCodec, NULL) >= 0 &&
                    av_read_frame(imageInput, packet) >= 0 &&
                    avcodec_send_packet(imageDecoder, packet) >= 0 &&
                    avcodec_receive_frame(imageDecoder, imageFrame) >= 0) {
                    scaler = sws_getContext(imageFrame->width, imageFrame->height,
                        (enum AVPixelFormat)imageFrame->format, width, height,
                        AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
                    if (scaler != NULL) {
                        sws_scale(scaler, imageFrame->data, imageFrame->linesize,
                                  0, imageFrame->height, videoFrame->data,
                                  videoFrame->linesize);
                    }
                    YTKACEDownloadLog(@"convert", @"artwork frame %dx%d scaler=%d",
                        imageFrame->width, imageFrame->height, scaler != NULL);
                }
                av_packet_unref(packet);
            }
        }

        const int64_t duration = audioInput->duration > 0
            ? audioInput->duration / AV_TIME_BASE : 0;
        const int64_t frames = MAX((int64_t)1, duration);
        for (int64_t index = 0; index < frames; index++) {
            if (YTKACEConversionCancelled(identifier)) {
                error = YTKACEConversionCancelledError();
                goto finish;
            }
            videoFrame->pts = index;
            if (avcodec_send_frame(encoder, videoFrame) >= 0) {
                status = YTKACEDrainEncoder(encoder, output, videoStream, encoded);
                if (status < 0) {
                    error = YTKACEFFmpegError(status, @"Write video");
                    goto finish;
                }
            }
            if (progress != nil && frames > 0) {
                progress(MIN(1.0, (double)(index + 1) / (double)frames));
            }
        }
        avcodec_send_frame(encoder, NULL);
        status = YTKACEDrainEncoder(encoder, output, videoStream, encoded);
        if (status < 0) {
            error = YTKACEFFmpegError(status, @"Write video");
            goto finish;
        }

        uint32_t audioPackets = 0;
        while ((status = av_read_frame(audioInput, packet)) >= 0) {
            if ((++audioPackets & 0xFF) == 0 &&
                YTKACEConversionCancelled(identifier)) {
                av_packet_unref(packet);
                error = YTKACEConversionCancelledError();
                goto finish;
            }
            if (packet->stream_index == audioIndex) {
                packet->stream_index = audioStream->index;
                av_packet_rescale_ts(packet,
                    audioInput->streams[audioIndex]->time_base,
                    audioStream->time_base);
                packet->pos = -1;
                status = av_interleaved_write_frame(output, packet);
                if (status < 0) {
                    av_packet_unref(packet);
                    error = YTKACEFFmpegError(status, @"Write audio");
                    goto finish;
                }
            }
            av_packet_unref(packet);
        }
        if (status != AVERROR_EOF) {
            error = YTKACEFFmpegError(status, @"Read audio");
            goto finish;
        }
        status = av_write_trailer(output);
        if (status < 0) {
            error = YTKACEFFmpegError(status, @"Write trailer");
            goto finish;
        }
    }

finish:
    if (scaler != NULL) sws_freeContext(scaler);
    if (imageDecoder != NULL) avcodec_free_context(&imageDecoder);
    if (encoder != NULL) avcodec_free_context(&encoder);
    if (output != NULL) {
        if (output->pb != NULL && !(output->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&output->pb);
        }
        avformat_free_context(output);
    }
    if (imageInput != NULL) avformat_close_input(&imageInput);
    if (audioInput != NULL) avformat_close_input(&audioInput);
    av_frame_free(&imageFrame);
    av_frame_free(&videoFrame);
    av_packet_free(&packet);
    av_packet_free(&encoded);
    if (artworkPath != nil) {
        [NSFileManager.defaultManager removeItemAtPath:artworkPath error:NULL];
    }
    if (error != nil) {
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:NULL];
    }
    return error;
}

static NSArray<NSDictionary *> *YTKACENormalizedCues(NSArray<NSDictionary *> *cues) {
    NSCharacterSet *invisible = [NSCharacterSet characterSetWithCharactersInString:@"\u200b\u200c\u200d\ufeff"];
    NSMutableArray<NSMutableDictionary *> *clean = [NSMutableArray array];
    for (NSDictionary *cue in cues) {
        NSString *text = cue[@"text"];
        if (![text isKindOfClass:NSString.class]) continue;
        text = [[text componentsSeparatedByCharactersInSet:invisible] componentsJoinedByString:@""];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length != 0) [lines addObject:trimmed];
        }
        text = [lines componentsJoinedByString:@"\n"];
        double start = [cue[@"start"] doubleValue];
        double end = [cue[@"end"] doubleValue];
        if (text.length == 0 || !isfinite(start) || !isfinite(end) || end - start < 0.05) continue;
        [clean addObject:[@{@"text": text, @"start": @(start), @"end": @(end)} mutableCopy]];
    }
    [clean sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"start"] compare:right[@"start"]];
    }];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSMutableDictionary *cue in clean) {
        NSMutableDictionary *previous = (NSMutableDictionary *)result.lastObject;
        double start = [cue[@"start"] doubleValue];
        if (previous != nil) {
            double previousStart = [previous[@"start"] doubleValue];
            if (start - previousStart < 0.05) {
                if ([cue[@"text"] length] >= [previous[@"text"] length]) {
                    previous[@"text"] = cue[@"text"];
                }
                previous[@"end"] = @(MAX([previous[@"end"] doubleValue], [cue[@"end"] doubleValue]));
                continue;
            }
            if ([previous[@"end"] doubleValue] > start) previous[@"end"] = @(start);
            if ([previous[@"text"] isEqualToString:cue[@"text"]]) {
                previous[@"end"] = cue[@"end"];
                continue;
            }
        }
        [result addObject:cue];
    }
    return result;
}

static NSString *YTKACEMP4LanguageCode(NSString *language) {
    NSString *base = [[language.lowercaseString componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    if (base.length == 3) return base;
    static NSDictionary<NSString *, NSString *> *codes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = @{@"af": @"afr", @"am": @"amh", @"ar": @"ara", @"az": @"aze", @"be": @"bel", @"bg": @"bul", @"bn": @"ben", @"bs": @"bos", @"ca": @"cat", @"cs": @"ces", @"cy": @"cym", @"da": @"dan", @"de": @"deu", @"el": @"ell", @"en": @"eng", @"es": @"spa", @"et": @"est", @"eu": @"eus", @"fa": @"fas", @"fi": @"fin", @"fil": @"fil", @"fr": @"fra", @"ga": @"gle", @"gl": @"glg", @"gu": @"guj", @"he": @"heb", @"iw": @"heb", @"hi": @"hin", @"hr": @"hrv", @"hu": @"hun", @"hy": @"hye", @"id": @"ind", @"is": @"isl", @"it": @"ita", @"ja": @"jpn", @"jv": @"jav", @"ka": @"kat", @"kk": @"kaz", @"km": @"khm", @"kn": @"kan", @"ko": @"kor", @"ku": @"kur", @"ky": @"kir", @"lo": @"lao", @"lt": @"lit", @"lv": @"lav", @"mk": @"mkd", @"ml": @"mal", @"mn": @"mon", @"mr": @"mar", @"ms": @"msa", @"my": @"mya", @"ne": @"nep", @"nl": @"nld", @"no": @"nor", @"nb": @"nob", @"pa": @"pan", @"pl": @"pol", @"ps": @"pus", @"pt": @"por", @"ro": @"ron", @"ru": @"rus", @"si": @"sin", @"sk": @"slk", @"sl": @"slv", @"so": @"som", @"sq": @"sqi", @"sr": @"srp", @"sv": @"swe", @"sw": @"swa", @"ta": @"tam", @"te": @"tel", @"th": @"tha", @"tl": @"tgl", @"tr": @"tur", @"uk": @"ukr", @"ur": @"urd", @"uz": @"uzb", @"vi": @"vie", @"zh": @"zho", @"zu": @"zul"};
    });
    return base.length != 0 ? codes[base] : nil;
}

@implementation YTKACEFFmpegMuxer

+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        av_log_set_level(AV_LOG_ERROR);
        NSError *error = YTKACERemuxAudio(audioURL, outputURL);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        av_log_set_level(AV_LOG_ERROR);
        NSError *error = YTKACERemux(videoURL, audioURL, outputURL);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

+ (void)normalizeMediaURL:(NSURL *)mediaURL
                outputURL:(NSURL *)outputURL
               completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        av_log_set_level(AV_LOG_ERROR);
        NSError *error = YTKACERemux(mediaURL, mediaURL, outputURL);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

static uint64_t YTKACEReadBE(const uint8_t *bytes, NSUInteger count) {
    uint64_t value = 0;
    for (NSUInteger index = 0; index < count; index++) {
        value = (value << 8) | bytes[index];
    }
    return value;
}

// Largest moov box we are willing to load to patch subtitles. A moov is
// sample tables only (no media), so even multi-hour videos stay far below it.
static const uint64_t YTKACEMaxPatchedMoovSize = 64ull * 1024 * 1024;

// Rewrites the tx3g sample entries so iOS draws the subtitles bottom-centered
// at a readable size. Only the moov box is read and written back in place at
// the same offset (the patch never changes its length), so large videos are
// never loaded into memory and mdat media bytes are never scanned or touched.
// Returns 1 when patched, 0 when there was nothing to patch, -1 when writing
// the patch failed (the file may then be damaged and must not be used).
static int YTKACEPatchTextSampleDescription(NSURL *URL,
                                            int width,
                                            int height) {
    NSError *ioError = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingURL:URL
                                                            error:&ioError];
    if (handle == nil) {
        YTKACEDownloadLog(@"subs", @"tx3g patch open failed: %@",
                          ioError.localizedDescription);
        return 0;
    }
    unsigned long long fileSize = 0;
    if (![handle seekToEndReturningOffset:&fileSize error:&ioError]) {
        [handle closeAndReturnError:nil];
        return 0;
    }
    uint64_t offset = 0;
    uint64_t moovOffset = 0;
    uint64_t moovSize = 0;
    while (offset + 8 <= fileSize) {
        if (![handle seekToOffset:offset error:&ioError]) break;
        NSData *header = [handle readDataUpToLength:16 error:&ioError];
        if (header.length < 8) break;
        const uint8_t *box = (const uint8_t *)header.bytes;
        uint64_t size = YTKACEReadBE(box, 4);
        uint64_t headerSize = 8;
        if (size == 1) {
            if (header.length < 16) break;
            size = YTKACEReadBE(box + 8, 8);
            headerSize = 16;
        } else if (size == 0) {
            size = fileSize - offset;
        }
        if (size < headerSize || size > fileSize - offset) break;
        if (memcmp(box + 4, "moov", 4) == 0) {
            moovOffset = offset;
            moovSize = size;
            break;
        }
        offset += size;
    }
    if (moovSize < 64) {
        [handle closeAndReturnError:nil];
        return 0;
    }
    if (moovSize > YTKACEMaxPatchedMoovSize) {
        YTKACEDownloadLog(@"subs", @"tx3g patch skipped: moov is %llu bytes",
                          (unsigned long long)moovSize);
        [handle closeAndReturnError:nil];
        return 0;
    }
    NSData *moov = nil;
    if ([handle seekToOffset:moovOffset error:&ioError]) {
        moov = [handle readDataUpToLength:(NSUInteger)moovSize error:&ioError];
    }
    if (moov.length != moovSize) {
        [handle closeAndReturnError:nil];
        return 0;
    }
    NSMutableData *data = [moov mutableCopy];
    moov = nil;
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    const NSUInteger length = data.length;
    NSUInteger patched = 0;
    for (NSUInteger index = 4; index + 46 <= length; index++) {
        if (memcmp(bytes + index, "tx3g", 4) != 0) continue;
        const NSUInteger entry = index - 4;
        const uint32_t size = ((uint32_t)bytes[entry] << 24) |
            ((uint32_t)bytes[entry + 1] << 16) |
            ((uint32_t)bytes[entry + 2] << 8) | bytes[entry + 3];
        if (size < 46 || entry + size > length) continue;
        NSUInteger cursor = entry + 16;
        if (cursor + 30 > length) continue;
        memset(bytes + cursor, 0, 4);
        cursor += 4;
        bytes[cursor++] = 0x01;
        bytes[cursor++] = 0xFF;
        memset(bytes + cursor, 0, 4);
        cursor += 4;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = (uint8_t)((height >> 8) & 0xFF);
        bytes[cursor++] = (uint8_t)(height & 0xFF);
        bytes[cursor++] = (uint8_t)((width >> 8) & 0xFF);
        bytes[cursor++] = (uint8_t)(width & 0xFF);
        memset(bytes + cursor, 0, 4);
        cursor += 4;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = 0x01;
        bytes[cursor++] = 0x00;
        bytes[cursor++] = (uint8_t)MAX(16, MIN(72, height / 20));
        bytes[cursor++] = 0xFF;
        bytes[cursor++] = 0xFF;
        bytes[cursor++] = 0xFF;
        bytes[cursor++] = 0xFF;
        patched++;
    }
    if (patched == 0) {
        [handle closeAndReturnError:nil];
        return 0;
    }
    if (![handle seekToOffset:moovOffset error:&ioError] ||
        ![handle writeData:data error:&ioError] ||
        ![handle synchronizeAndReturnError:&ioError]) {
        YTKACEDownloadLog(@"subs", @"tx3g patch write failed: %@",
                          ioError.localizedDescription);
        [handle closeAndReturnError:nil];
        return -1;
    }
    if (![handle closeAndReturnError:&ioError]) {
        YTKACEDownloadLog(@"subs", @"tx3g patch close failed: %@",
                          ioError.localizedDescription);
        return -1;
    }
    YTKACEDownloadLog(@"subs", @"patched %lu tx3g entries %dx%d",
                      (unsigned long)patched, width, height);
    return 1;
}

+ (void)muxSubtitlesIntoURL:(NSURL *)mediaURL
                       cues:(NSArray<NSDictionary *> *)cues
                   language:(NSString *)language
                  outputURL:(NSURL *)outputURL
                 completion:(YTKACEFFmpegCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVFormatContext *input = NULL;
        AVFormatContext *output = NULL;
        int *streamMap = NULL;
        AVPacket *packet = NULL;
        AVStream *text = NULL;
        NSError *failure = nil;
        int textIndex = -1;
        int status = 0;
        int videoWidth = 1280;
        int videoHeight = 720;
        long written = 0;

        do {
            status = avformat_open_input(
                &input, mediaURL.fileSystemRepresentation, NULL, NULL);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle open");
                break;
            }
            status = avformat_find_stream_info(input, NULL);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle probe");
                break;
            }
            status = avformat_alloc_output_context2(
                &output, NULL, "mp4", outputURL.fileSystemRepresentation);
            if (status < 0 || output == NULL) {
                failure = YTKACEFFmpegError(status, @"subtitle output");
                break;
            }
            streamMap = (int *)av_calloc(input->nb_streams, sizeof(int));
            if (streamMap == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM), @"subtitle map");
                break;
            }
            for (unsigned int index = 0; index < input->nb_streams; index++) {
                AVStream *source = input->streams[index];
                const enum YTKACEFFmpegMediaType type =
                    source->codecpar->codec_type;
                if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) {
                    streamMap[index] = -1;
                    continue;
                }
                AVStream *copy = avformat_new_stream(output, NULL);
                if (copy == NULL) {
                    failure = YTKACEFFmpegError(AVERROR(ENOMEM),
                                                @"subtitle stream");
                    break;
                }
                status = avcodec_parameters_copy(copy->codecpar,
                                                 source->codecpar);
                if (status < 0) {
                    failure = YTKACEFFmpegError(status, @"subtitle params");
                    break;
                }
                if (type == AVMEDIA_TYPE_VIDEO) {
                    if (source->codecpar->width > 0) {
                        videoWidth = source->codecpar->width;
                    }
                    if (source->codecpar->height > 0) {
                        videoHeight = source->codecpar->height;
                    }
                }
                copy->codecpar->codec_tag = 0;
                copy->time_base = source->time_base;
                streamMap[index] = (int)(output->nb_streams - 1);
            }
            if (failure != nil) break;

            text = avformat_new_stream(output, NULL);
            if (text == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM), @"subtitle track");
                break;
            }
            text->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
            text->codecpar->codec_id = AV_CODEC_ID_MOV_TEXT;
            text->time_base = (AVRational){1, 1000};
            text->disposition = AV_DISPOSITION_DEFAULT;
            uint8_t description[48];
            size_t cursor = 0;
            memset(description, 0, sizeof(description));
            cursor += 4;
            description[cursor++] = 0x01;
            description[cursor++] = 0xFF;
            cursor += 4;
            description[cursor++] = 0x00;
            description[cursor++] = 0x00;
            description[cursor++] = 0x00;
            description[cursor++] = 0x00;
            description[cursor++] = (uint8_t)((videoHeight >> 8) & 0xFF);
            description[cursor++] = (uint8_t)(videoHeight & 0xFF);
            description[cursor++] = (uint8_t)((videoWidth >> 8) & 0xFF);
            description[cursor++] = (uint8_t)(videoWidth & 0xFF);
            cursor += 4;
            description[cursor++] = 0x00;
            description[cursor++] = 0x01;
            description[cursor++] = 0x00;
            description[cursor++] = (uint8_t)MAX(16, MIN(72, videoHeight / 20));
            description[cursor++] = 0xFF;
            description[cursor++] = 0xFF;
            description[cursor++] = 0xFF;
            description[cursor++] = 0xFF;
            static const uint8_t fontTable[] = {
                0x00, 0x00, 0x00, 0x12, 0x66, 0x74, 0x61, 0x62,
                0x00, 0x01, 0x00, 0x01, 0x05, 0x53, 0x65, 0x72,
                0x69, 0x66
            };
            memcpy(description + cursor, fontTable, sizeof(fontTable));
            cursor += sizeof(fontTable);

            text->codecpar->extradata = (uint8_t *)av_mallocz(
                cursor + AV_INPUT_BUFFER_PADDING_SIZE);
            if (text->codecpar->extradata == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM),
                                            @"subtitle extradata");
                break;
            }
            memcpy(text->codecpar->extradata, description, cursor);
            text->codecpar->extradata_size = (int)cursor;
            text->codecpar->width = videoWidth;
            text->codecpar->height = videoHeight;
            YTKACEDownloadLog(@"subs", @"tx3g desc %zu bytes box=%dx%d",
                              cursor, videoWidth, videoHeight);
            NSString *mp4Language = YTKACEMP4LanguageCode(language);
            if (mp4Language.length != 0) {
                av_dict_set(&text->metadata, "language", mp4Language.UTF8String, 0);
            }
            textIndex = (int)(output->nb_streams - 1);

            if (!(output->oformat->flags & AVFMT_NOFILE)) {
                status = avio_open(&output->pb,
                                   outputURL.fileSystemRepresentation,
                                   AVIO_FLAG_WRITE);
                if (status < 0) {
                    failure = YTKACEFFmpegError(status, @"subtitle avio");
                    break;
                }
            }
            status = avformat_write_header(output, NULL);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle header");
                break;
            }

            packet = av_packet_alloc();
            if (packet == NULL) {
                failure = YTKACEFFmpegError(AVERROR(ENOMEM), @"subtitle packet");
                break;
            }
            // nb_streams can grow while reading (streams found after the
            // header); those were never mapped, so remember the mapped count.
            const unsigned int mappedStreams = input->nb_streams;
            while ((status = av_read_frame(input, packet)) >= 0) {
                if (packet->stream_index < 0 ||
                    (unsigned int)packet->stream_index >= mappedStreams ||
                    streamMap[packet->stream_index] < 0) {
                    av_packet_unref(packet);
                    continue;
                }
                const int mapped = streamMap[packet->stream_index];
                AVStream *source = input->streams[packet->stream_index];
                AVStream *destination = output->streams[mapped];
                av_packet_rescale_ts(packet, source->time_base,
                                     destination->time_base);
                packet->stream_index = mapped;
                packet->pos = -1;
                status = av_interleaved_write_frame(output, packet);
                av_packet_unref(packet);
                if (status < 0) {
                    failure = YTKACEFFmpegError(status, @"subtitle media write");
                    break;
                }
            }
            if (failure != nil) break;
            if (status != AVERROR_EOF) {
                failure = YTKACEFFmpegError(status, @"subtitle media read");
                break;
            }

            for (NSDictionary *cue in YTKACENormalizedCues(cues)) {
                NSString *value = cue[@"text"];
                if (![value isKindOfClass:NSString.class] || value.length == 0) {
                    continue;
                }
                NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
                if (utf8.length == 0 || utf8.length > 0xFFFF) continue;
                const double start = [cue[@"start"] doubleValue];
                const double end = [cue[@"end"] doubleValue];
                if (end <= start) continue;
                if (av_new_packet(packet, (int)utf8.length + 2) < 0) continue;
                packet->data[0] = (uint8_t)((utf8.length >> 8) & 0xFF);
                packet->data[1] = (uint8_t)(utf8.length & 0xFF);
                memcpy(packet->data + 2, utf8.bytes, utf8.length);
                packet->stream_index = textIndex;
                packet->pts = (int64_t)(start * 1000.0);
                packet->dts = packet->pts;
                packet->duration = (int64_t)((end - start) * 1000.0);
                packet->pos = -1;
                const int rc = av_interleaved_write_frame(output, packet);
                av_packet_unref(packet);
                if (rc < 0) {
                    YTKACEDownloadLog(@"subs", @"cue write failed: %@",
                                      YTKACEFFmpegMessage(rc));
                    failure = YTKACEFFmpegError(rc, @"subtitle cue write");
                    break;
                }
                written++;
            }
            if (failure != nil) break;

            status = av_write_trailer(output);
            if (status < 0) {
                failure = YTKACEFFmpegError(status, @"subtitle trailer");
            }
        } while (0);

        if (packet != NULL) av_packet_free(&packet);
        if (streamMap != NULL) av_free(streamMap);
        if (input != NULL) avformat_close_input(&input);
        if (output != NULL) {
            if (output->pb != NULL && !(output->oformat->flags & AVFMT_NOFILE)) {
                avio_closep(&output->pb);
            }
            avformat_free_context(output);
        }
        if (failure == nil) {
            YTKACEDownloadLog(@"subs", @"muxed %ld/%lu cues written",
                              (long)written, (unsigned long)cues.count);
            const int patch = YTKACEPatchTextSampleDescription(
                outputURL, videoWidth, videoHeight);
            if (patch == 0) {
                YTKACEDownloadLog(@"subs", @"tx3g patch skipped");
            } else if (patch < 0) {
                failure = YTKACEFFmpegError(AVERROR(EIO), @"subtitle patch");
            }
        }
        if (failure != nil) {
            [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            YTKACEDownloadLog(@"subs", @"mux failed: %@",
                              failure.localizedDescription);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure); });
    });
}

+ (void)embedArtworkData:(NSData *)artworkData
                 mediaURL:(NSURL *)mediaURL
               completion:(YTKACEFFmpegCompletion)completion {
    if (artworkData.length == 0 || mediaURL == nil) {
        completion(YTKACEFFmpegError(AVERROR(EINVAL), @"Read artwork"));
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:nil];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc]
        initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (exporter == nil) {
        completion(YTKACEFFmpegError(AVERROR_UNKNOWN, @"Create artwork export"));
        return;
    }
    NSString *extension = mediaURL.pathExtension.lowercaseString;
    AVFileType outputType = [extension isEqualToString:@"m4a"]
        ? AVFileTypeAppleM4A : AVFileTypeMPEG4;
    if (![exporter.supportedFileTypes containsObject:outputType]) {
        completion(YTKACEFFmpegError(AVERROR(ENOTSUP), @"Embed artwork"));
        return;
    }
    NSURL *temporary = [mediaURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:[NSString stringWithFormat:@".%@-artwork.%@",
            NSUUID.UUID.UUIDString, extension.length == 0 ? @"mp4" : extension]];
    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    AVMutableMetadataItem *artwork = [AVMutableMetadataItem metadataItem];
    artwork.identifier = AVMetadataCommonIdentifierArtwork;
    artwork.value = artworkData;
    artwork.dataType = @"com.apple.metadata.datatype.JPEG";
    NSMutableArray<AVMetadataItem *> *metadata = [asset.commonMetadata mutableCopy] ?:
        [NSMutableArray array];
    [metadata addObject:artwork];
    exporter.metadata = metadata;
    exporter.outputURL = temporary;
    exporter.outputFileType = outputType;
    exporter.shouldOptimizeForNetworkUse = YES;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        NSError *error = exporter.error;
        if (exporter.status == AVAssetExportSessionStatusCompleted) {
            NSFileManager *manager = NSFileManager.defaultManager;
            copyfile(mediaURL.fileSystemRepresentation, temporary.fileSystemRepresentation,
                     NULL, COPYFILE_XATTR);
            NSURL *backup = [mediaURL.URLByDeletingLastPathComponent
                URLByAppendingPathComponent:[@"." stringByAppendingString:
                    NSUUID.UUID.UUIDString]];
            if (![manager moveItemAtURL:mediaURL toURL:backup error:&error] ||
                ![manager moveItemAtURL:temporary toURL:mediaURL error:&error]) {
                if (![manager fileExistsAtPath:mediaURL.path]) {
                    [manager moveItemAtURL:backup toURL:mediaURL error:nil];
                }
            } else {
                [manager removeItemAtURL:backup error:nil];
            }
        }
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}


+ (void)videoFromAudioURL:(NSURL *)audioURL
             artworkData:(NSData *)artworkData
                outputURL:(NSURL *)outputURL
               identifier:(NSString *)identifier
                 progress:(YTKACEFFmpegProgress)progress
               completion:(YTKACEFFmpegCompletion)completion {
    NSString *token = [identifier copy];
    // Registered before the hop so a cancel that arrives while the block is
    // still queued is not lost.
    YTKACEBeginConversion(token);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        NSError *error = YTKACEAudioToVideo(audioURL, artworkData, outputURL,
                                            token, progress);
        YTKACEEndConversion(token);
        YTKACEDownloadLog(@"convert", @"audio video elapsed=%.1fs error=%@",
            CFAbsoluteTimeGetCurrent() - started,
            error.localizedDescription ?: @"none");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}


@end
