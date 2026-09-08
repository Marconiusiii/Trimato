#include "CaptureBuffer.h"
#include <stdatomic.h>
#include <stdlib.h>
struct TCaptureBuffer {
    _Atomic uint64_t head, tail, deliveries;
    _Atomic int accepting, active, received, failure, deviceStatus;
    uint32_t slots, capacity;
    uint32_t *lengths;
    float *samples;
};
TCaptureBuffer *TCaptureCreate(uint32_t slots, uint32_t capacity) {
    TCaptureBuffer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    atomic_init(&r->head, 0); atomic_init(&r->tail, 0); atomic_init(&r->deliveries, 0);
    atomic_init(&r->accepting, 0); atomic_init(&r->active, 0);
    atomic_init(&r->received, 0); atomic_init(&r->failure, 0); atomic_init(&r->deviceStatus, 0);
    _Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2, "Capture needs lock-free atomics");
    r->slots = slots; r->capacity = capacity;
    r->lengths = calloc(slots, sizeof(uint32_t));
    r->samples = calloc((size_t)slots * capacity, sizeof(float));
    if (!r->lengths || !r->samples) { TCaptureDestroy(r); return NULL; }
    return r;
}
void TCaptureDestroy(TCaptureBuffer *r) { if (r) { free(r->lengths); free(r->samples); free(r); } }
void TCaptureBegin(TCaptureBuffer *r) { atomic_store(&r->accepting, 1); }
void TCaptureStop(TCaptureBuffer *r) { atomic_store(&r->accepting, 0); }
int TCaptureActive(TCaptureBuffer *r) { return atomic_load(&r->active); }
int TCaptureReceived(TCaptureBuffer *r) { return atomic_load(&r->received); }
uint64_t TCaptureDeliveries(TCaptureBuffer *r) { return atomic_load(&r->deliveries); }
int TCaptureFailure(TCaptureBuffer *r) { return atomic_load(&r->failure); }
void TCaptureDeviceError(TCaptureBuffer *r, int32_t status) { atomic_store(&r->deviceStatus, status); int expected = 0; atomic_compare_exchange_strong(&r->failure, &expected, 3); }
int32_t TCaptureDeviceStatus(TCaptureBuffer *r) { return atomic_load(&r->deviceStatus); }
void TCapturePush(TCaptureBuffer *r, const float *source, uint32_t frames, uint32_t stride, int valid) {
    atomic_fetch_add(&r->active, 1);
    if (valid && frames) { atomic_store(&r->received, 1); atomic_fetch_add(&r->deliveries, 1); }
    if (atomic_load(&r->accepting) && !atomic_load(&r->failure)) {
        uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
        uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
        if (!valid || !source || frames > r->capacity) atomic_store(&r->failure, 1);
        else if (head - tail >= r->slots) atomic_store(&r->failure, 2);
        else {
            uint32_t slot = (uint32_t)(head % r->slots);
            float *destination = r->samples + (size_t)slot * r->capacity;
            for (uint32_t i = 0; i < frames; i++) destination[i] = source[(size_t)i * stride];
            r->lengths[slot] = frames;
            atomic_store_explicit(&r->head, head + 1, memory_order_release);
        }
    }
    atomic_fetch_sub(&r->active, 1);
}
const float *TCapturePeek(TCaptureBuffer *r, uint32_t *frames) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    if (tail == atomic_load_explicit(&r->head, memory_order_acquire)) return NULL;
    uint32_t slot = (uint32_t)(tail % r->slots);
    *frames = r->lengths[slot];
    return r->samples + (size_t)slot * r->capacity;
}
void TCaptureConsume(TCaptureBuffer *r) { atomic_fetch_add_explicit(&r->tail, 1, memory_order_release); }
