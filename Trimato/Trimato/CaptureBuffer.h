#ifndef TRIMATO_CAPTURE_BUFFER_H
#define TRIMATO_CAPTURE_BUFFER_H
#include <stdint.h>
typedef struct TCaptureBuffer TCaptureBuffer;
TCaptureBuffer *TCaptureCreate(uint32_t slots, uint32_t capacity);
void TCaptureDestroy(TCaptureBuffer *ring);
void TCaptureBegin(TCaptureBuffer *ring);
void TCaptureStop(TCaptureBuffer *ring);
int TCaptureActive(TCaptureBuffer *ring);
int TCaptureReceived(TCaptureBuffer *ring);
int TCaptureFailure(TCaptureBuffer *ring);
void TCapturePush(TCaptureBuffer *ring, const float *source, uint32_t frames, uint32_t stride, int valid);
const float *TCapturePeek(TCaptureBuffer *ring, uint32_t *frames);
void TCaptureConsume(TCaptureBuffer *ring);
#endif
