// ZSSG's bridge to libavif. The decode and encode settings mirror Hugo's
// internal/warpc/genavif/avif.c (Hugo 0.170.0) so that ZSSG produces the same
// pixels and files: dav1d for decoding, aom for encoding, one thread.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "avif/avif.h"

typedef struct {
    uint32_t width, height, depth, rgb_depth, row_bytes;
    int color_primaries, transfer, matrix, max_cll, max_pall;
    uint8_t *pixels; // RGBA, 8 or 16 (little-endian) bits per channel; free with zssg_avif_free
} ZssgAvifImage;

void zssg_avif_free(void *p) { free(p); }

int zssg_avif_decode(const uint8_t *data, size_t len, ZssgAvifImage *out, char *err, size_t errlen)
{
    memset(out, 0, sizeof(*out));
    avifDecoder *decoder = avifDecoderCreate();
    if (!decoder) { snprintf(err, errlen, "Failed to create AVIF decoder"); return 0; }
    decoder->ignoreExif = AVIF_TRUE;
    decoder->ignoreXMP = AVIF_TRUE;
    decoder->maxThreads = 1;
    decoder->codecChoice = AVIF_CODEC_CHOICE_DAV1D;
    decoder->imageContentToDecode = AVIF_IMAGE_CONTENT_ALL;
    avifResult r = avifDecoderSetIOMemory(decoder, data, len);
    if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to set IO memory: %s", avifResultToString(r)); avifDecoderDestroy(decoder); return 0; }
    r = avifDecoderParse(decoder);
    if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to parse AVIF: %s", avifResultToString(r)); avifDecoderDestroy(decoder); return 0; }

    if (decoder->image->gainMap != NULL && decoder->image->gainMap->image != NULL) {
        r = avifDecoderNextImage(decoder);
        if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to decode AVIF for gain map: %s", avifResultToString(r)); avifDecoderDestroy(decoder); return 0; }
        avifRGBImage rgb;
        memset(&rgb, 0, sizeof(rgb));
        avifRGBImageSetDefaults(&rgb, decoder->image);
        rgb.format = AVIF_RGB_FORMAT_RGBA;
        rgb.depth = 16;
        if (avifRGBImageAllocatePixels(&rgb) != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to allocate RGB pixels for gain map apply"); avifDecoderDestroy(decoder); return 0; }
        float headroom = 0.0f;
        const avifUnsignedFraction *h = &decoder->image->gainMap->alternateHdrHeadroom;
        if (h->d != 0) headroom = (float)h->n / (float)h->d;
        avifContentLightLevelInformationBox clli = {0};
        r = avifImageApplyGainMap(decoder->image, decoder->image->gainMap, headroom, AVIF_COLOR_PRIMARIES_BT2020, AVIF_TRANSFER_CHARACTERISTICS_PQ, &rgb, &clli, NULL);
        if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to apply gain map: %s", avifResultToString(r)); avifRGBImageFreePixels(&rgb); avifDecoderDestroy(decoder); return 0; }
        size_t n = (size_t)rgb.rowBytes * rgb.height;
        out->pixels = malloc(n);
        if (!out->pixels) { avifRGBImageFreePixels(&rgb); avifDecoderDestroy(decoder); snprintf(err, errlen, "out of memory"); return 0; }
        memcpy(out->pixels, rgb.pixels, n);
        out->width = rgb.width; out->height = rgb.height; out->depth = 10; out->rgb_depth = 16; out->row_bytes = rgb.rowBytes;
        out->color_primaries = AVIF_COLOR_PRIMARIES_BT2020;
        out->transfer = AVIF_TRANSFER_CHARACTERISTICS_PQ;
        out->matrix = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
        out->max_cll = clli.maxCLL; out->max_pall = clli.maxPALL;
        avifRGBImageFreePixels(&rgb);
        avifDecoderDestroy(decoder);
        return 1;
    }

    out->width = decoder->image->width;
    out->height = decoder->image->height;
    out->depth = decoder->image->depth;
    out->color_primaries = decoder->image->colorPrimaries;
    out->transfer = decoder->image->transferCharacteristics;
    out->matrix = decoder->image->matrixCoefficients;
    int rgb_depth = (decoder->image->depth > 8) ? 16 : 8;
    uint32_t bpp = (rgb_depth == 16) ? 8 : 4;
    uint32_t row_bytes = decoder->image->width * bpp;
    out->rgb_depth = rgb_depth;
    out->row_bytes = row_bytes;
    out->pixels = malloc((size_t)row_bytes * decoder->image->height);
    if (!out->pixels) { snprintf(err, errlen, "Failed to allocate memory for decoded image"); avifDecoderDestroy(decoder); return 0; }
    avifRGBImage rgb;
    memset(&rgb, 0, sizeof(rgb));
    avifRGBImageSetDefaults(&rgb, decoder->image);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.depth = rgb_depth;
    rgb.rowBytes = row_bytes;
    rgb.pixels = out->pixels;
    r = avifDecoderNextImage(decoder);
    if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to decode AVIF frame 0: %s", avifResultToString(r)); free(out->pixels); out->pixels = NULL; avifDecoderDestroy(decoder); return 0; }
    r = avifImageYUVToRGB(decoder->image, &rgb);
    if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "Failed to convert to RGBA: %s", avifResultToString(r)); free(out->pixels); out->pixels = NULL; avifDecoderDestroy(decoder); return 0; }
    avifDecoderDestroy(decoder);
    return 1;
}

static void set_color(avifImage *image, int depth, int cp, int tc, int mc, int max_cll, int max_pall)
{
    if (cp > 0) {
        image->colorPrimaries = cp;
        image->transferCharacteristics = tc;
        image->matrixCoefficients = mc;
    } else if (depth > 8) {
        image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
        image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_PQ;
        image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
    } else {
        image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
        image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
        image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;
    }
    image->yuvRange = AVIF_RANGE_FULL;
    if (max_cll > 0 || max_pall > 0) {
        image->clli.maxCLL = (uint16_t)max_cll;
        image->clli.maxPALL = (uint16_t)max_pall;
    }
}

static int finish_encode(avifImage *image, int gray, float quality, int lossless, int speed, uint8_t **out, size_t *out_len, char *err, size_t errlen, const char *what)
{
    avifEncoder *encoder = avifEncoderCreate();
    if (!encoder) { snprintf(err, errlen, "%s: Failed to create encoder", what); return 0; }
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
    if (lossless) {
        encoder->quality = AVIF_QUALITY_LOSSLESS;
        if (!gray) encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
    } else {
        if (quality < 1) quality = 1;
        if (quality > 100) quality = 100;
        int q = (int)((quality - 1.0) / 99.0 * 100.0);
        if (q >= AVIF_QUALITY_LOSSLESS) q = AVIF_QUALITY_LOSSLESS - 1;
        encoder->quality = q;
        if (!gray) encoder->qualityAlpha = q;
    }
    if (gray) encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
    encoder->speed = (speed >= 1 && speed <= 10) ? speed : 10;
    encoder->autoTiling = AVIF_TRUE;
    avifResult r = avifEncoderAddImage(encoder, image, 1, AVIF_ADD_IMAGE_FLAG_SINGLE);
    if (r != AVIF_RESULT_OK) {
        snprintf(err, errlen, "%s: Failed to add image to encoder: %s%s%s", what, avifResultToString(r), encoder->diag.error[0] ? ": " : "", encoder->diag.error);
        avifEncoderDestroy(encoder);
        return 0;
    }
    avifRWData raw = { NULL, 0 };
    r = avifEncoderFinish(encoder, &raw);
    if (r != AVIF_RESULT_OK) {
        snprintf(err, errlen, "%s: Failed to finish encoding: %s%s%s", what, avifResultToString(r), encoder->diag.error[0] ? ": " : "", encoder->diag.error);
        avifEncoderDestroy(encoder);
        return 0;
    }
    *out = malloc(raw.size);
    if (*out) memcpy(*out, raw.data, raw.size);
    *out_len = raw.size;
    avifRWDataFree(&raw);
    avifEncoderDestroy(encoder);
    return *out != NULL;
}

// RGBA (8-bit, or 16-bit little-endian when depth > 8) to AVIF.
int zssg_avif_encode_rgba(const uint8_t *pixels, uint32_t width, uint32_t height, uint32_t stride, int depth,
                         int cp, int tc, int mc, int max_cll, int max_pall,
                         float quality, int lossless, int yuv444, int speed,
                         uint8_t **out, size_t *out_len, char *err, size_t errlen)
{
    if (depth == 0) depth = 8;
    int rgb_depth = (depth > 8) ? 16 : 8;
    avifPixelFormat fmt = (yuv444 || lossless) ? AVIF_PIXEL_FORMAT_YUV444 : AVIF_PIXEL_FORMAT_YUV420;
    avifImage *image = avifImageCreate(width, height, depth, fmt);
    if (!image) { snprintf(err, errlen, "encodeNRGBA: Failed to create avifImage"); return 0; }
    set_color(image, depth, cp, tc, mc, max_cll, max_pall);
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.depth = rgb_depth;
    rgb.pixels = (uint8_t *)pixels;
    rgb.rowBytes = stride;
    avifResult r = avifImageRGBToYUV(image, &rgb);
    if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "encodeNRGBA: Failed to convert to YUV: %s", avifResultToString(r)); avifImageDestroy(image); return 0; }
    int ok = finish_encode(image, 0, quality, lossless, speed, out, out_len, err, errlen, "encodeNRGBA");
    avifImageDestroy(image);
    return ok;
}

// Gray (8-bit, or 16-bit when depth > 8) to AVIF (4:0:0).
int zssg_avif_encode_gray(const uint8_t *pixels, uint32_t width, uint32_t height, uint32_t stride, int depth,
                         float quality, int lossless, int speed,
                         uint8_t **out, size_t *out_len, char *err, size_t errlen)
{
    if (depth == 0) depth = 8;
    int bps = (depth > 8) ? 2 : 1;
    avifImage *image = avifImageCreate(width, height, depth, AVIF_PIXEL_FORMAT_YUV400);
    if (!image) { snprintf(err, errlen, "encodeGray: Failed to create avifImage"); return 0; }
    set_color(image, depth, 0, 0, 0, 0, 0);
    avifResult r = avifImageAllocatePlanes(image, AVIF_PLANES_YUV);
    if (r != AVIF_RESULT_OK) { snprintf(err, errlen, "encodeGray: Failed to allocate planes: %s", avifResultToString(r)); avifImageDestroy(image); return 0; }
    for (uint32_t i = 0; i < height; ++i)
        memcpy(image->yuvPlanes[AVIF_CHAN_Y] + (size_t)i * image->yuvRowBytes[AVIF_CHAN_Y], pixels + (size_t)i * stride, (size_t)width * bps);
    int ok = finish_encode(image, 1, quality, lossless, speed, out, out_len, err, errlen, "encodeGray");
    avifImageDestroy(image);
    return ok;
}
