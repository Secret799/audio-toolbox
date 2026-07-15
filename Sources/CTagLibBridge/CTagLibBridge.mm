#include "CTagLibBridge.h"

#include <taglib/audioproperties.h>
#include <taglib/fileref.h>
#include <taglib/tag.h>
#include <taglib/tfile.h>
#include <taglib/tstring.h>

#include <unistd.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <limits>
#include <new>
#include <string>

namespace {
constexpr int32_t ATStatusInvalidPath = 1;
constexpr int32_t ATStatusUnreadable = 2;
constexpr int32_t ATStatusMissingTag = 3;
constexpr int32_t ATStatusAllocationFailure = 4;
constexpr int32_t ATStatusUnexpectedFailure = 5;
constexpr int32_t ATStatusNotWritable = 6;
constexpr int32_t ATStatusSaveFailed = 7;
constexpr size_t ATHeaderProbeSize = 64 * 1024;

ATReadResult EmptyReadResult() {
    return ATReadResult{0, nullptr, nullptr, nullptr, 0, nullptr};
}

ATWriteResult EmptyWriteResult() {
    return ATWriteResult{0, nullptr};
}

void ReleaseReadResult(ATReadResult &result) {
    std::free(result.title);
    std::free(result.artist);
    std::free(result.album);
    std::free(result.error_message);
    result = EmptyReadResult();
}

void ReleaseWriteResult(ATWriteResult &result) {
    std::free(result.error_message);
    result = EmptyWriteResult();
}

char *DuplicateUTF8(const std::string &value) {
    return value.empty() ? nullptr : ::strdup(value.c_str());
}

char *DuplicateUTF8(const TagLib::String &value) {
    return value.isEmpty() ? nullptr : DuplicateUTF8(value.to8Bit(true));
}

void SetError(ATReadResult &result, int32_t status, const char *message) {
    result.status = status;
    result.error_message = message == nullptr ? nullptr : ::strdup(message);
}

void SetError(ATWriteResult &result, int32_t status, const char *message) {
    result.status = status;
    result.error_message = message == nullptr ? nullptr : ::strdup(message);
}

bool CopyTagStrings(const TagLib::Tag &tag, ATReadResult &result) {
    result.title = DuplicateUTF8(tag.title());
    if(!tag.title().isEmpty() && result.title == nullptr) {
        return false;
    }

    result.artist = DuplicateUTF8(tag.artist());
    if(!tag.artist().isEmpty() && result.artist == nullptr) {
        return false;
    }

    result.album = DuplicateUTF8(tag.album());
    if(!tag.album().isEmpty() && result.album == nullptr) {
        return false;
    }

    return true;
}

enum class ATContainer {
    Unknown,
    MPEGAudio,
    MP4,
    FLAC,
    WAV,
    Ogg,
    RawADTS
};

struct ATFileProbe {
    std::array<unsigned char, ATHeaderProbeSize> bytes{};
    size_t size = 0;
    uint64_t file_size = 0;
    uint64_t file_offset = 0;
    bool has_leading_id3 = false;
};

bool AddWithinFile(uint64_t base, uint64_t addition, uint64_t file_size, uint64_t &sum) {
    if(addition > std::numeric_limits<uint64_t>::max() - base) {
        return false;
    }

    sum = base + addition;
    return sum <= file_size;
}

bool ReadProbeAt(
    std::ifstream &stream,
    uint64_t file_size,
    uint64_t file_offset,
    bool has_leading_id3,
    ATFileProbe &probe
) {
    if(file_offset > file_size
        || file_offset > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())) {
        return false;
    }

    const uint64_t remaining = file_size - file_offset;
    const size_t requested = remaining < ATHeaderProbeSize
        ? static_cast<size_t>(remaining)
        : ATHeaderProbeSize;

    stream.clear();
    stream.seekg(static_cast<std::streamoff>(file_offset), std::ios::beg);
    if(!stream) {
        return false;
    }

    stream.read(reinterpret_cast<char *>(probe.bytes.data()),
                static_cast<std::streamsize>(requested));
    probe.size = static_cast<size_t>(stream.gcount());
    probe.file_size = file_size;
    probe.file_offset = file_offset;
    probe.has_leading_id3 = has_leading_id3;
    return probe.size == requested;
}

bool ReadFileProbe(const char *path, ATFileProbe &probe) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if(!stream) {
        return false;
    }

    const std::streamoff end = stream.tellg();
    if(end <= 0) {
        return false;
    }
    const uint64_t file_size = static_cast<uint64_t>(end);

    std::array<unsigned char, 10> prefix{};
    const size_t prefix_size = file_size < prefix.size()
        ? static_cast<size_t>(file_size)
        : prefix.size();

    stream.seekg(0, std::ios::beg);
    if(!stream) {
        return false;
    }
    stream.read(reinterpret_cast<char *>(prefix.data()),
                static_cast<std::streamsize>(prefix_size));
    if(static_cast<size_t>(stream.gcount()) != prefix_size) {
        return false;
    }

    const bool has_id3 = prefix_size >= 3
        && std::memcmp(prefix.data(), "ID3", 3) == 0;
    if(!has_id3) {
        return ReadProbeAt(stream, file_size, 0, false, probe);
    }

    if(prefix_size < prefix.size()) {
        return false;
    }

    const unsigned int major_version = prefix[3];
    if((major_version != 2 && major_version != 3 && major_version != 4)
        || prefix[4] == 0xFF) {
        return false;
    }

    unsigned char allowed_flags = 0;
    if(major_version == 2) {
        allowed_flags = 0xC0;
    }
    else if(major_version == 3) {
        allowed_flags = 0xE0;
    }
    else {
        allowed_flags = 0xF0;
    }
    if((prefix[5] & static_cast<unsigned char>(~allowed_flags)) != 0) {
        return false;
    }

    for(size_t index = 6; index <= 9; ++index) {
        if((prefix[index] & 0x80) != 0) {
            return false;
        }
    }

    const uint64_t declared_size = (static_cast<uint64_t>(prefix[6]) << 21)
        | (static_cast<uint64_t>(prefix[7]) << 14)
        | (static_cast<uint64_t>(prefix[8]) << 7)
        | static_cast<uint64_t>(prefix[9]);
    uint64_t payload_offset = 0;
    if(!AddWithinFile(10, declared_size, file_size, payload_offset)) {
        return false;
    }

    if(major_version == 4 && (prefix[5] & 0x10) != 0) {
        const uint64_t footer_start = payload_offset;
        if(!AddWithinFile(footer_start, 10, file_size, payload_offset)
            || footer_start > static_cast<uint64_t>(
                std::numeric_limits<std::streamoff>::max()
            )) {
            return false;
        }

        std::array<unsigned char, 10> footer{};
        stream.clear();
        stream.seekg(static_cast<std::streamoff>(footer_start), std::ios::beg);
        if(!stream) {
            return false;
        }
        stream.read(reinterpret_cast<char *>(footer.data()),
                    static_cast<std::streamsize>(footer.size()));
        if(static_cast<size_t>(stream.gcount()) != footer.size()) {
            return false;
        }

        for(size_t index = 6; index <= 9; ++index) {
            if((footer[index] & 0x80) != 0) {
                return false;
            }
        }
        if(std::memcmp(footer.data(), "3DI", 3) != 0
            || footer[3] != prefix[3]
            || footer[4] != prefix[4]
            || footer[5] != prefix[5]
            || std::memcmp(footer.data() + 6, prefix.data() + 6, 4) != 0) {
            return false;
        }
    }

    return ReadProbeAt(stream, file_size, payload_offset, true, probe);
}

bool StartsWith(const ATFileProbe &probe, const char *value, size_t length) {
    return probe.size >= length
        && std::memcmp(probe.bytes.data(), value, length) == 0;
}

uint32_t ReadBigEndian32(const unsigned char *bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24)
        | (static_cast<uint32_t>(bytes[1]) << 16)
        | (static_cast<uint32_t>(bytes[2]) << 8)
        | static_cast<uint32_t>(bytes[3]);
}

uint64_t ReadBigEndian64(const unsigned char *bytes) {
    return (static_cast<uint64_t>(ReadBigEndian32(bytes)) << 32)
        | static_cast<uint64_t>(ReadBigEndian32(bytes + 4));
}

bool HasMP4FileTypeBox(const ATFileProbe &probe) {
    if(probe.has_leading_id3 || probe.file_offset != 0) {
        return false;
    }

    size_t offset = 0;
    while(offset + 8 <= probe.size) {
        const unsigned char *box = probe.bytes.data() + offset;
        uint64_t box_size = ReadBigEndian32(box);
        uint64_t box_header_size = 8;

        if(box_size == 1) {
            if(offset + 16 > probe.size) {
                return false;
            }
            box_size = ReadBigEndian64(box + 8);
            box_header_size = 16;
        }
        else if(box_size == 0) {
            box_size = probe.file_size - offset;
        }

        if(box_size < box_header_size || box_size > probe.file_size - offset) {
            return false;
        }

        if(std::memcmp(box + 4, "ftyp", 4) == 0) {
            return box_size >= box_header_size + 8;
        }

        if(box_size > probe.size - offset) {
            return false;
        }
        offset += static_cast<size_t>(box_size);
    }

    return false;
}

bool IsRawADTSFrameAt(const ATFileProbe &probe, size_t offset) {
    if(offset + 7 > probe.size || offset > probe.file_size - probe.file_offset) {
        return false;
    }

    const unsigned char *frame = probe.bytes.data() + offset;
    if(frame[0] != 0xFF || (frame[1] & 0xF6) != 0xF0) {
        return false;
    }

    const unsigned int sample_rate_index = (frame[2] >> 2) & 0x0F;
    if(sample_rate_index == 0x0F) {
        return false;
    }

    const uint32_t frame_length = (static_cast<uint32_t>(frame[3] & 0x03) << 11)
        | (static_cast<uint32_t>(frame[4]) << 3)
        | (static_cast<uint32_t>(frame[5]) >> 5);
    const uint64_t absolute_offset = probe.file_offset + offset;
    return frame_length >= 7 && frame_length <= probe.file_size - absolute_offset;
}

bool IsMPEGAudioFrameAt(const ATFileProbe &probe, size_t offset) {
    if(offset + 4 > probe.size) {
        return false;
    }

    const unsigned char *frame = probe.bytes.data() + offset;
    if(frame[0] != 0xFF || (frame[1] & 0xE0) != 0xE0) {
        return false;
    }

    const unsigned int version = (frame[1] >> 3) & 0x03;
    const unsigned int layer = (frame[1] >> 1) & 0x03;
    const unsigned int bitrate_index = (frame[2] >> 4) & 0x0F;
    const unsigned int sample_rate_index = (frame[2] >> 2) & 0x03;

    return version != 0x01
        && layer != 0x00
        && bitrate_index != 0x00
        && bitrate_index != 0x0F
        && sample_rate_index != 0x03;
}

ATContainer DetectContainer(const ATFileProbe &probe) {
    if(probe.has_leading_id3) {
        if(StartsWith(probe, "fLaC", 4)) {
            return ATContainer::FLAC;
        }
        if(IsRawADTSFrameAt(probe, 0)) {
            return ATContainer::RawADTS;
        }
        for(size_t offset = 0; offset + 4 <= probe.size; ++offset) {
            if(IsMPEGAudioFrameAt(probe, offset)) {
                return ATContainer::MPEGAudio;
            }
        }
        return ATContainer::Unknown;
    }

    if(StartsWith(probe, "fLaC", 4)) {
        return ATContainer::FLAC;
    }
    if(StartsWith(probe, "OggS", 4)) {
        return ATContainer::Ogg;
    }
    if(probe.size >= 12
        && (StartsWith(probe, "RIFF", 4) || StartsWith(probe, "RF64", 4))
        && std::memcmp(probe.bytes.data() + 8, "WAVE", 4) == 0) {
        return ATContainer::WAV;
    }
    if(HasMP4FileTypeBox(probe)) {
        return ATContainer::MP4;
    }
    if(IsRawADTSFrameAt(probe, 0)) {
        return ATContainer::RawADTS;
    }

    for(size_t offset = 0; offset + 4 <= probe.size; ++offset) {
        if(IsMPEGAudioFrameAt(probe, offset)) {
            return ATContainer::MPEGAudio;
        }
    }

    return ATContainer::Unknown;
}

bool ASCIIEqualIgnoringCase(const char *value, const char *expected) {
    while(*value != '\0' && *expected != '\0') {
        char left = *value;
        char right = *expected;
        if(left >= 'A' && left <= 'Z') {
            left = static_cast<char>(left - 'A' + 'a');
        }
        if(right >= 'A' && right <= 'Z') {
            right = static_cast<char>(right - 'A' + 'a');
        }
        if(left != right) {
            return false;
        }
        ++value;
        ++expected;
    }
    return *value == '\0' && *expected == '\0';
}

ATContainer ContainerForExtension(const char *path) {
    const char *extension = std::strrchr(path, '.');
    const char *slash = std::strrchr(path, '/');
    if(extension == nullptr || (slash != nullptr && extension < slash) || extension[1] == '\0') {
        return ATContainer::Unknown;
    }

    ++extension;
    if(ASCIIEqualIgnoringCase(extension, "mp3")) {
        return ATContainer::MPEGAudio;
    }
    if(ASCIIEqualIgnoringCase(extension, "m4a")
        || ASCIIEqualIgnoringCase(extension, "mp4")) {
        return ATContainer::MP4;
    }
    if(ASCIIEqualIgnoringCase(extension, "flac")) {
        return ATContainer::FLAC;
    }
    if(ASCIIEqualIgnoringCase(extension, "wav")) {
        return ATContainer::WAV;
    }
    if(ASCIIEqualIgnoringCase(extension, "ogg")
        || ASCIIEqualIgnoringCase(extension, "oga")) {
        return ATContainer::Ogg;
    }
    if(ASCIIEqualIgnoringCase(extension, "aac")) {
        return ATContainer::RawADTS;
    }
    return ATContainer::Unknown;
}

bool ContentMatchesExtension(const char *path, bool require_writable_container) {
    ATFileProbe probe;
    if(!ReadFileProbe(path, probe)) {
        return false;
    }

    const ATContainer detected = DetectContainer(probe);
    const ATContainer expected = ContainerForExtension(path);
    if(detected == ATContainer::Unknown || detected != expected) {
        return false;
    }
    return !require_writable_container || detected != ATContainer::RawADTS;
}

bool HasSaneAudioProperties(const TagLib::FileRef &file) {
    const TagLib::AudioProperties *properties = file.audioProperties();
    if(properties == nullptr
        || properties->lengthInMilliseconds() <= 0
        || properties->sampleRate() < 1000
        || properties->sampleRate() > 768000
        || properties->channels() <= 0
        || properties->channels() > 64) {
        return false;
    }

    const int bitrate = properties->bitrate();
    return bitrate >= 0 && bitrate <= 1000000;
}

bool IsUsableFileRef(const TagLib::FileRef &file, bool require_writable) {
    if(file.isNull() || file.tag() == nullptr || file.file() == nullptr
        || !file.file()->isValid() || !HasSaneAudioProperties(file)) {
        return false;
    }
    return !require_writable || !file.file()->readOnly();
}
}  // namespace

ATReadResult ATReadMetadata(const char *path) {
    ATReadResult result = EmptyReadResult();

    try {
        if(path == nullptr || path[0] == '\0') {
            SetError(result, ATStatusInvalidPath, "音频文件路径为空");
            return result;
        }
        if(::access(path, R_OK) != 0) {
            SetError(result, ATStatusUnreadable, "无法打开或识别音频文件");
            return result;
        }
        if(!ContentMatchesExtension(path, false)) {
            SetError(result, ATStatusUnreadable, "音频内容与扩展名不匹配或格式不受支持");
            return result;
        }

        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!IsUsableFileRef(file, false)) {
            SetError(result, ATStatusUnreadable, "无法打开或识别音频文件");
            return result;
        }

        const TagLib::Tag *tag = file.tag();
        if(tag == nullptr || tag->isEmpty()) {
            SetError(result, ATStatusMissingTag, "音频文件不包含可读取的标签");
            return result;
        }

        if(!CopyTagStrings(*tag, result)) {
            ReleaseReadResult(result);
            SetError(result, ATStatusAllocationFailure, "读取音频标签时内存分配失败");
            return result;
        }

        result.duration_seconds = static_cast<double>(
            file.audioProperties()->lengthInMilliseconds()
        ) / 1000.0;
        return result;
    }
    catch(const std::bad_alloc &) {
        ReleaseReadResult(result);
        SetError(result, ATStatusAllocationFailure, "读取音频标签时内存分配失败");
        return result;
    }
    catch(const std::exception &) {
        ReleaseReadResult(result);
        SetError(result, ATStatusUnexpectedFailure, "读取音频标签时发生内部错误");
        return result;
    }
    catch(...) {
        ReleaseReadResult(result);
        SetError(result, ATStatusUnexpectedFailure, "读取音频标签时发生未知错误");
        return result;
    }
}

void ATFreeReadResult(ATReadResult *result) {
    try {
        if(result != nullptr) {
            ReleaseReadResult(*result);
        }
    }
    catch(...) {
    }
}

bool ATCanWriteMetadata(const char *path) {
    try {
        if(path == nullptr || path[0] == '\0' || ::access(path, W_OK) != 0
            || !ContentMatchesExtension(path, true)) {
            return false;
        }

        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        return IsUsableFileRef(file, true);
    }
    catch(...) {
        return false;
    }
}

ATWriteResult ATWriteMetadata(
    const char *path,
    const char *artist_or_null,
    const char *album_or_null
) {
    ATWriteResult result = EmptyWriteResult();

    try {
        if(path == nullptr || path[0] == '\0') {
            SetError(result, ATStatusInvalidPath, "音频文件路径为空");
            return result;
        }
        if(::access(path, W_OK) != 0) {
            SetError(result, ATStatusNotWritable, "音频文件不可写");
            return result;
        }
        if(!ContentMatchesExtension(path, true)) {
            SetError(result, ATStatusNotWritable, "音频内容与扩展名不匹配或格式不支持写入");
            return result;
        }

        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!IsUsableFileRef(file, true)) {
            SetError(result, ATStatusNotWritable, "音频文件不可写或音频属性无效");
            return result;
        }

        TagLib::Tag *tag = file.tag();
        if(tag == nullptr) {
            SetError(result, ATStatusMissingTag, "音频文件不包含可写标签");
            return result;
        }

        if(artist_or_null != nullptr) {
            tag->setArtist(TagLib::String(artist_or_null, TagLib::String::UTF8));
        }
        if(album_or_null != nullptr) {
            tag->setAlbum(TagLib::String(album_or_null, TagLib::String::UTF8));
        }

        if(!file.save()) {
            SetError(result, ATStatusSaveFailed, "TagLib 保存音频标签失败");
        }
        return result;
    }
    catch(const std::bad_alloc &) {
        ReleaseWriteResult(result);
        SetError(result, ATStatusAllocationFailure, "保存音频标签时内存分配失败");
        return result;
    }
    catch(const std::exception &) {
        ReleaseWriteResult(result);
        SetError(result, ATStatusUnexpectedFailure, "保存音频标签时发生内部错误");
        return result;
    }
    catch(...) {
        ReleaseWriteResult(result);
        SetError(result, ATStatusUnexpectedFailure, "保存音频标签时发生未知错误");
        return result;
    }
}

void ATFreeWriteResult(ATWriteResult *result) {
    try {
        if(result != nullptr) {
            ReleaseWriteResult(*result);
        }
    }
    catch(...) {
    }
}
