//
//  BXImportTranscode.m
//  导入时把任意视频规整成「标准 mp4」：
//    · 视频：H.264（优先 h264_videotoolbox 硬编，退 mpeg4 软编）
//    · 尺寸：等比缩放到不超过 1080x1920（偶数对齐）
//    · 帧率：固定 30fps（CFR，逐帧给 pts，杜绝 VFR 导致的音画不同步）
//    · 音频：AAC 44.1kHz 立体声
//  这正是原版的行为（二进制里有 avcodec_find_encoder / avformat_write_header /
//  h264_videotoolbox 和「正在导入视频，请稍候」）。
//

#import <Foundation/Foundation.h>
#import "BXLog.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#define BX_LOG(fmt, ...) BXLog(@"[BXFloat][import] " fmt, ##__VA_ARGS__)

static const int kOutFPS = 30;
static const int kMaxW   = 1080;
static const int kMaxH   = 1920;
static const int64_t kVideoBitrate = 4000000;

// 等比缩放到不超过 kMaxW/kMaxH，宽高取偶数
static void BXFitSize(int sw, int sh, int *dw, int *dh) {
    if (sw <= 0 || sh <= 0) { *dw = 720; *dh = 1280; return; }
    double scale = 1.0;
    if (sw > kMaxW || sh > kMaxH) {
        double sx = (double)kMaxW / sw, sy = (double)kMaxH / sh;
        scale = sx < sy ? sx : sy;
    }
    int w = (int)(sw * scale) & ~1;
    int h = (int)(sh * scale) & ~1;
    if (w < 16) w = 16;
    if (h < 16) h = 16;
    *dw = w; *dh = h;
}

static int BXOpenDecoder(AVFormatContext *in, int streamIdx, AVCodecContext **out) {
    if (streamIdx < 0) return -1;
    AVCodecParameters *par = in->streams[streamIdx]->codecpar;
    const AVCodec *dec = avcodec_find_decoder(par->codec_id);
    if (!dec) return -1;
    AVCodecContext *c = avcodec_alloc_context3(dec);
    if (!c) return -1;
    if (avcodec_parameters_to_context(c, par) < 0 || avcodec_open2(c, dec, NULL) < 0) {
        avcodec_free_context(&c);
        return -1;
    }
    *out = c;
    return 0;
}

NSString *BXTranscodeToStandardMP4(NSString *inPath, NSString *outDir) {
    if (!inPath.length) return nil;

    AVFormatContext *in = NULL;
    if (avformat_open_input(&in, inPath.UTF8String, NULL, NULL) < 0 || !in) {
        BX_LOG(@"打开输入失败: %@", inPath.lastPathComponent);
        return nil;
    }
    if (avformat_find_stream_info(in, NULL) < 0) {
        BX_LOG(@"读取流信息失败");
        avformat_close_input(&in);
        return nil;
    }

    int vIdx = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int aIdx = av_find_best_stream(in, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (vIdx < 0) {
        BX_LOG(@"没有视频轨");
        avformat_close_input(&in);
        return nil;
    }

    AVCodecContext *vdec = NULL, *adec = NULL;
    if (BXOpenDecoder(in, vIdx, &vdec) != 0) {
        BX_LOG(@"视频解码器打开失败 codec=%d", in->streams[vIdx]->codecpar->codec_id);
        avformat_close_input(&in);
        return nil;
    }
    if (aIdx >= 0 && BXOpenDecoder(in, aIdx, &adec) != 0) aIdx = -1;

    int srcW = vdec->width, srcH = vdec->height;
    if (srcW <= 0 || srcH <= 0) {
        srcW = in->streams[vIdx]->codecpar->width;
        srcH = in->streams[vIdx]->codecpar->height;
    }
    int dstW = 0, dstH = 0;
    BXFitSize(srcW, srcH, &dstW, &dstH);
    BX_LOG(@"转码 %@ : %dx%d → %dx%d @%dfps", inPath.lastPathComponent, srcW, srcH, dstW, dstH, kOutFPS);

    // ---- 输出 ----
    NSString *name = [NSString stringWithFormat:@"bx_import_%@.mp4",
                      [[NSUUID UUID].UUIDString substringToIndex:8]];
    NSString *outPath = [outDir stringByAppendingPathComponent:name];

    BOOL ok = YES;
    AVFormatContext *oc = NULL;
    if (avformat_alloc_output_context2(&oc, NULL, "mp4", outPath.UTF8String) < 0 || !oc) {
        BX_LOG(@"创建输出容器失败");
        avcodec_free_context(&vdec);
        if (adec) avcodec_free_context(&adec);
        avformat_close_input(&in);
        return nil;
    }

    // ---- 视频编码器：优先 VT 硬编 ----
    const AVCodec *venc_codec = avcodec_find_encoder_by_name("h264_videotoolbox");
    BX_LOG(@"候选编码器 h264_videotoolbox = %s", venc_codec ? "有" : "无");
    if (!venc_codec) venc_codec = avcodec_find_encoder(AV_CODEC_ID_H264);
    if (!venc_codec) venc_codec = avcodec_find_encoder(AV_CODEC_ID_MPEG4);
    if (!venc_codec) {
        BX_LOG(@"没有可用视频编码器");
        avformat_free_context(oc);
        avcodec_free_context(&vdec);
        if (adec) avcodec_free_context(&adec);
        avformat_close_input(&in);
        return nil;
    }
    BX_LOG(@"视频编码器: %s", venc_codec->name);

    AVCodecContext *venc = avcodec_alloc_context3(venc_codec);
    venc->width = dstW;
    venc->height = dstH;
    venc->time_base = (AVRational){1, kOutFPS};
    venc->framerate = (AVRational){kOutFPS, 1};
    venc->gop_size = kOutFPS;
    venc->max_b_frames = 0;
    venc->bit_rate = kVideoBitrate;
    venc->pix_fmt = (venc_codec->pix_fmts && venc_codec->pix_fmts[0] != AV_PIX_FMT_NONE)
                    ? venc_codec->pix_fmts[0] : AV_PIX_FMT_YUV420P;
    if (oc->oformat->flags & AVFMT_GLOBALHEADER) venc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    int vopen = avcodec_open2(venc, venc_codec, NULL);
    if (vopen < 0) {
        BX_LOG(@"视频编码器打开失败 %s (%d)，尝试 mpeg4", venc_codec->name, vopen);
        avcodec_free_context(&venc);
        const AVCodec *alt = avcodec_find_encoder(AV_CODEC_ID_MPEG4);
        if (alt) {
            venc = avcodec_alloc_context3(alt);
            venc->width = dstW; venc->height = dstH;
            venc->time_base = (AVRational){1, kOutFPS};
            venc->framerate = (AVRational){kOutFPS, 1};
            venc->gop_size = kOutFPS; venc->max_b_frames = 0;
            venc->bit_rate = kVideoBitrate;
            venc->pix_fmt = alt->pix_fmts ? alt->pix_fmts[0] : AV_PIX_FMT_YUV420P;
            if (oc->oformat->flags & AVFMT_GLOBALHEADER) venc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            vopen = avcodec_open2(venc, alt, NULL);
            venc_codec = alt;
        }
    }
    if (vopen < 0) {
        BX_LOG(@"mpeg4 也打不开，转码放弃 (%d)", vopen);
        avcodec_free_context(&venc);
        avformat_free_context(oc);
        avcodec_free_context(&vdec);
        if (adec) avcodec_free_context(&adec);
        avformat_close_input(&in);
        return nil;
    }

    AVStream *vst = avformat_new_stream(oc, NULL);
    vst->time_base = venc->time_base;
    avcodec_parameters_from_context(vst->codecpar, venc);

    // ---- 音频编码器：AAC ----
    AVCodecContext *aenc = NULL;
    AVStream *ast = NULL;
    if (aIdx >= 0) {
        const AVCodec *aenc_codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (aenc_codec) {
            aenc = avcodec_alloc_context3(aenc_codec);
            aenc->sample_rate = 44100;
            aenc->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
            aenc->sample_fmt = aenc_codec->sample_fmts ? aenc_codec->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
            aenc->bit_rate = 128000;
            aenc->time_base = (AVRational){1, 44100};
            if (oc->oformat->flags & AVFMT_GLOBALHEADER) aenc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            if (avcodec_open2(aenc, aenc_codec, NULL) < 0) {
                avcodec_free_context(&aenc);
                aenc = NULL;
            } else {
                ast = avformat_new_stream(oc, NULL);
                ast->time_base = aenc->time_base;
                avcodec_parameters_from_context(ast->codecpar, aenc);
            }
        }
    }

    int aio = avio_open(&oc->pb, outPath.UTF8String, AVIO_FLAG_WRITE);
    if (aio < 0) { BX_LOG(@"avio_open 失败 %d", aio);
        BX_LOG(@"打开输出文件失败");
        goto fail;
    }
    int wh = avformat_write_header(oc, NULL);
    if (wh < 0) { BX_LOG(@"write_header 失败 %d", wh);
        BX_LOG(@"写容器头失败");
        goto fail;
    }

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frm = av_frame_alloc();
    struct SwsContext *sws = NULL;
    int64_t vFrameIdx = 0;

    while (av_read_frame(in, pkt) >= 0) {
        if (pkt->stream_index == vIdx) {
            if (avcodec_send_packet(vdec, pkt) >= 0) {
                while (avcodec_receive_frame(vdec, frm) >= 0) {
                    if (!sws) {
                        sws = sws_getContext(frm->width, frm->height, frm->format,
                                             dstW, dstH, venc->pix_fmt,
                                             SWS_BILINEAR, NULL, NULL, NULL);
                        if (!sws) { av_packet_unref(pkt); goto done; }
                    }
                    AVFrame *of = av_frame_alloc();
                    of->format = venc->pix_fmt;
                    of->width = dstW;
                    of->height = dstH;
                    av_frame_get_buffer(of, 32);
                    av_frame_make_writable(of);
                    sws_scale(sws, (const uint8_t *const *)frm->data, frm->linesize, 0,
                              frm->height, of->data, of->linesize);
                    of->pts = vFrameIdx++;
                    of->duration = 1;

                    if (avcodec_send_frame(venc, of) >= 0) {
                        AVPacket *op = av_packet_alloc();
                        while (avcodec_receive_packet(venc, op) >= 0) {
                            av_packet_rescale_ts(op, venc->time_base, vst->time_base);
                            op->stream_index = vst->index;
                            av_interleaved_write_frame(oc, op);
                            av_packet_unref(op);
                        }
                        av_packet_free(&op);
                    }
                    av_frame_free(&of);
                }
            }
        } else if (aIdx >= 0 && aenc && pkt->stream_index == aIdx) {
            if (avcodec_send_packet(adec, pkt) >= 0) {
                while (avcodec_receive_frame(adec, frm) >= 0) {
                    static struct SwrContext *swr = NULL;
                    if (!swr) {
                        AVChannelLayout inL = frm->ch_layout;
                        swr_alloc_set_opts2(&swr, &aenc->ch_layout, aenc->sample_fmt,
                                            aenc->sample_rate, &inL, frm->format,
                                            frm->sample_rate, 0, NULL);
                        if (!swr || swr_init(swr) < 0) { av_frame_unref(frm); break; }
                    }
                    int outSamples = (int)av_rescale_rnd(swr_get_delay(swr, frm->sample_rate) + frm->nb_samples,
                                                         aenc->sample_rate, frm->sample_rate, AV_ROUND_UP);
                    AVFrame *af = av_frame_alloc();
                    af->format = aenc->sample_fmt;
                    af->ch_layout = aenc->ch_layout;
                    af->sample_rate = aenc->sample_rate;
                    af->nb_samples = outSamples;
                    af->pts = av_rescale_q(frm->pts, in->streams[aIdx]->time_base, aenc->time_base);
                    if (av_frame_get_buffer(af, 0) < 0) { av_frame_free(&af); av_frame_unref(frm); continue; }
                    swr_convert(swr, af->data, outSamples,
                                (const uint8_t **)frm->extended_data, frm->nb_samples);
                    if (avcodec_send_frame(aenc, af) >= 0) {
                        AVPacket *op = av_packet_alloc();
                        while (avcodec_receive_packet(aenc, op) >= 0) {
                            av_packet_rescale_ts(op, aenc->time_base, ast->time_base);
                            op->stream_index = ast->index;
                            av_interleaved_write_frame(oc, op);
                            av_packet_unref(op);
                        }
                        av_packet_free(&op);
                    }
                    av_frame_free(&af);
                }
            }
        }
        av_packet_unref(pkt);
    }

done:
    // flush
    avcodec_send_packet(vdec, NULL);
    avcodec_send_packet(venc, NULL);
    {
        AVPacket *op = av_packet_alloc();
        while (avcodec_receive_packet(venc, op) >= 0) {
            av_packet_rescale_ts(op, venc->time_base, vst->time_base);
            op->stream_index = vst->index;
            av_interleaved_write_frame(oc, op);
            av_packet_unref(op);
        }
        av_packet_free(&op);
    }
    if (aenc) {
        avcodec_send_frame(aenc, NULL);
        AVPacket *op = av_packet_alloc();
        while (avcodec_receive_packet(aenc, op) >= 0) {
            av_packet_rescale_ts(op, aenc->time_base, ast->time_base);
            op->stream_index = ast->index;
            av_interleaved_write_frame(oc, op);
            av_packet_unref(op);
        }
        av_packet_free(&op);
    }
    av_write_trailer(oc);

    if (sws) sws_freeContext(sws);
    av_frame_free(&frm);
    av_packet_free(&pkt);
    BX_LOG(@"转码完成 %@ (帧数=%lld)", name, (long long)vFrameIdx);

    // 正常结束：先按成功路径收尾
    if (oc->pb) avio_closep(&oc->pb);
    if (aenc) avcodec_free_context(&aenc);
    avcodec_free_context(&venc);
    avformat_free_context(oc);
    avcodec_free_context(&vdec);
    if (adec) avcodec_free_context(&adec);
    avformat_close_input(&in);
    {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:nil];
        unsigned long long sz = attr ? [attr fileSize] : 0;
        if (vFrameIdx > 0 && sz > 4096) return outPath;
        BX_LOG(@"转码产物无效（帧数=%lld 大小=%llu），删除", (long long)vFrameIdx, sz);
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        return nil;
    }

fail:
    ok = NO;
    if (oc && oc->pb) avio_closep(&oc->pb);
    if (aenc) avcodec_free_context(&aenc);
    avcodec_free_context(&venc);
    avformat_free_context(oc);
    avcodec_free_context(&vdec);
    if (adec) avcodec_free_context(&adec);
    avformat_close_input(&in);
    if (ok && vFrameIdx > 0) return outPath;
    if (vFrameIdx <= 0) BX_LOG(@"转码失败：没有解出任何帧");
    /* 失败就把半成品删掉，绝不再把坏路径交给播放端 */
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    return nil;
}
