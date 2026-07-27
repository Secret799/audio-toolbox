#ifndef CTagLibTestSupport_h
#define CTagLibTestSupport_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

bool ATTestClearMetadata(const char *path);
bool ATTestTagIsEmpty(const char *path);
bool ATTestSeedRichMetadata(const char *path, bool include_unknown_mp3_frame);
bool ATTestSetProperty(const char *path, const char *key, const char *value);
char *ATTestPropertyValues(const char *path, const char *key);
char *ATTestCanonicalProperties(
    const char *path,
    bool exclude_artist,
    bool exclude_album,
    bool exclude_composer
);
char *ATTestUnsupportedData(const char *path);
size_t ATTestComplexPropertyCount(const char *path, const char *key);
bool ATTestHasID3v2Frame(const char *path, const char *identifier);
bool ATTestSetID3v2TextFrame(
    const char *path,
    const char *identifier,
    const char *value
);
bool ATTestSeedSecondaryMPEGTags(const char *path);
char *ATTestMPEGID3v1Bytes(const char *path);
char *ATTestMPEGAPEBytes(const char *path);
void ATTestFreeString(char *value);

#ifdef __cplusplus
}
#endif

#endif
