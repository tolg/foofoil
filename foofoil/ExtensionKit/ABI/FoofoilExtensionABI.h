// FoofoilExtensionABI.h
// Stable Extension API v1 C boundary. New fields may only be appended.

#ifndef FoofoilExtensionABI_h
#define FoofoilExtensionABI_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FOOFOIL_EXTENSION_API_V1 1u
#define FOOFOIL_EXTENSION_CREATE_SYMBOL "foofoil_extension_create"

typedef struct FoofoilExtensionInterfaceV1 {
    uint32_t api_version;
    size_t struct_size;
    void *context;

    // Input and output are UTF-8 JSON value messages. The extension owns output
    // until release_bytes is called by the Host.
    int32_t (*create_session)(
        void *context,
        const uint8_t *request_json,
        size_t request_length,
        uint8_t **session_json,
        size_t *session_length
    );
    int32_t (*perform_command)(
        void *context,
        const uint8_t *command_json,
        size_t command_length,
        uint8_t **session_json,
        size_t *session_length
    );
    void (*release_bytes)(void *context, uint8_t *bytes, size_t length);
    void (*destroy)(void *context);
} FoofoilExtensionInterfaceV1;

typedef const FoofoilExtensionInterfaceV1 *(*FoofoilExtensionCreateFunction)(uint32_t negotiated_api_version);

#ifdef __cplusplus
}
#endif

#endif /* FoofoilExtensionABI_h */
