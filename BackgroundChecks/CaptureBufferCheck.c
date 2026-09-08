#include "CaptureBuffer.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    TCaptureBuffer *ring = TCaptureCreate(2, 4);
    assert(ring);
    const float samples[] = {1, 9, 2, 9, 3, 9, 4, 9};
    uint32_t count = 0;
    TCapturePush(ring, samples, 4, 2, 1);
    assert(TCaptureReceived(ring) && !TCapturePeek(ring, &count));
    TCaptureBegin(ring);
    TCapturePush(ring, samples, 4, 2, 1);
    TCapturePush(ring, samples, 4, 2, 1);
    // A stalled consumer must stop capture without overwriting saved samples.
    TCapturePush(ring, samples, 4, 2, 1);
    assert(TCaptureFailure(ring) == 2);
    for (int block = 0; block < 2; block++) {
        const float *saved = TCapturePeek(ring, &count);
        assert(saved && count == 4);
        for (int i = 0; i < 4; i++) assert(saved[i] == i + 1);
        TCaptureConsume(ring);
    }
    assert(!TCapturePeek(ring, &count));
    TCaptureDestroy(ring);
    ring = TCaptureCreate(2, 4);
    TCaptureBegin(ring);
    // Repeated wraparound preserves order and the selected interleaved channel.
    for (int i = 0; i < 100000; i++) {
        TCapturePush(ring, samples, 4, 2, 1);
        const float *saved = TCapturePeek(ring, &count);
        assert(saved && count == 4 && saved[3] == 4);
        TCaptureConsume(ring);
    }
    TCaptureStop(ring);
    TCapturePush(ring, samples, 4, 2, 1);
    assert(!TCapturePeek(ring, &count) && !TCaptureActive(ring));
    TCaptureBegin(ring);
    TCapturePush(ring, samples, 5, 2, 1);
    assert(TCaptureFailure(ring) == 1);
    TCaptureDestroy(ring);
    puts("Capture buffering: overflow, ordering, stride, stop and invalid-format checks passed.");
}
