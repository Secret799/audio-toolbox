#include "CTagLibBridge.h"

#include <taglib/audioproperties.h>
#include <taglib/fileref.h>
#include <taglib/id3v2frame.h>
#include <taglib/id3v2header.h>
#include <taglib/id3v2tag.h>
#include <taglib/mpegfile.h>
#include <taglib/tag.h>
#include <taglib/textidentificationframe.h>
#include <taglib/tfile.h>
#include <taglib/tpropertymap.h>
#include <taglib/tstring.h>
#include <taglib/tstringlist.h>

#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <limits>
#include <new>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

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

void AppendLengthPrefixed(std::ostringstream &stream, const std::string &value) {
    stream << value.size() << ':' << value;
}

std::string CanonicalPropertyMap(
    const TagLib::PropertyMap &properties,
    bool exclude_artist,
    bool exclude_album
) {
    std::vector<std::pair<std::string, std::vector<std::string>>> entries;
    for(auto iterator = properties.cbegin(); iterator != properties.cend(); ++iterator) {
        const std::string key = iterator->first.upper().to8Bit(true);
        if((exclude_artist && key == "ARTIST") || (exclude_album && key == "ALBUM")) {
            continue;
        }

        std::vector<std::string> values;
        values.reserve(iterator->second.size());
        for(const auto &value : iterator->second) {
            values.push_back(value.to8Bit(true));
        }
        entries.emplace_back(key, std::move(values));
    }
    std::sort(entries.begin(), entries.end(), [](const auto &left, const auto &right) {
        return left.first < right.first;
    });

    std::ostringstream stream;
    for(const auto &entry : entries) {
        AppendLengthPrefixed(stream, entry.first);
        stream << '=' << entry.second.size() << '[';
        for(const auto &value : entry.second) {
            AppendLengthPrefixed(stream, value);
            stream << ';';
        }
        stream << "]\n";
    }
    return stream.str();
}

std::vector<std::string> CanonicalUnsupportedData(const TagLib::StringList &values) {
    std::vector<std::string> result;
    result.reserve(values.size());
    for(const auto &value : values) {
        result.push_back(value.to8Bit(true));
    }
    std::sort(result.begin(), result.end());
    return result;
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
    bool has_v24_footer = false;
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
    bool has_v24_footer,
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
    probe.has_v24_footer = has_v24_footer;
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
        return ReadProbeAt(stream, file_size, 0, false, false, probe);
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

    const bool has_v24_footer = major_version == 4 && (prefix[5] & 0x10) != 0;
    if(has_v24_footer) {
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

    return ReadProbeAt(stream, file_size, payload_offset, true, has_v24_footer, probe);
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

struct ATContentProbeResult {
    ATContainer container = ATContainer::Unknown;
    bool has_v24_footer = false;
};

bool ContentMatchesExtension(
    const char *path,
    bool require_writable_container,
    ATContentProbeResult &result
) {
    ATFileProbe probe;
    if(!ReadFileProbe(path, probe)) {
        return false;
    }

    result.container = DetectContainer(probe);
    result.has_v24_footer = probe.has_v24_footer;
    const ATContainer expected = ContainerForExtension(path);
    if(result.container == ATContainer::Unknown || result.container != expected) {
        return false;
    }
    return !require_writable_container || result.container != ATContainer::RawADTS;
}

bool IsFooterBearingMPEG(const ATContentProbeResult &result) {
    return result.container == ATContainer::MPEGAudio && result.has_v24_footer;
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
bool IsLosslesslyDowngradableID3v23Date(const TagLib::String &value) {
    if(value.size() == 4) {
        return true;
    }
    if(value.size() == 10) {
        return value[4] == '-' && value[7] == '-';
    }
    if(value.size() == 16) {
        return value[4] == '-'
            && value[7] == '-'
            && value[10] == 'T'
            && value[13] == ':';
    }
    return false;
}

void RetainNonstandardLegacyID3v23YearFrames(TagLib::MPEG::File &mpeg) {
    TagLib::ID3v2::Tag *id3v2 = mpeg.ID3v2Tag(false);
    if(id3v2 == nullptr || id3v2->header()->majorVersion() != 3) {
        return;
    }

    const TagLib::ID3v2::FrameList date_frames = id3v2->frameList("TDRC");
    for(TagLib::ID3v2::Frame *frame : date_frames) {
        auto *date = dynamic_cast<TagLib::ID3v2::TextIdentificationFrame *>(frame);
        if(date == nullptr
            || date->fieldList().size() != 1
            || IsLosslesslyDowngradableID3v23Date(date->fieldList().front())) {
            continue;
        }

        auto *legacy_year = new TagLib::ID3v2::TextIdentificationFrame(
            "TYER",
            date->textEncoding()
        );
        legacy_year->setText(date->fieldList());
        id3v2->addFrame(legacy_year);
        id3v2->removeFrame(frame, true);
    }
}

void RetainStandaloneLegacyID3v23TimeFrames(TagLib::MPEG::File &mpeg) {
    TagLib::ID3v2::Tag *id3v2 = mpeg.ID3v2Tag(false);
    if(id3v2 == nullptr
        || id3v2->header()->majorVersion() != 3
        || !id3v2->frameList("TDRC").isEmpty()) {
        return;
    }

    for(TagLib::ID3v2::Frame *frame : id3v2->frameList("TIME")) {
        if(frame != nullptr && frame->header() != nullptr) {
            // TagLib marks legacy v2.3 TIME frames for removal while parsing them.
            // The original frame is still valid in v2.3, so retain it unchanged.
            frame->header()->setTagAlterPreservation(false);
        }
    }
}

bool SaveMetadataFile(TagLib::FileRef &file) {
    auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file());
    if(mpeg == nullptr) {
        return file.save();
    }

    int tag_types = TagLib::MPEG::File::ID3v2;
    if(mpeg->hasID3v2Tag()) {
        tag_types = TagLib::MPEG::File::ID3v2;
    } else if(mpeg->hasAPETag()) {
        tag_types = TagLib::MPEG::File::APE;
    } else if(mpeg->hasID3v1Tag()) {
        tag_types = TagLib::MPEG::File::ID3v1;
    }

    TagLib::ID3v2::Version version = TagLib::ID3v2::v4;
    if(TagLib::ID3v2::Tag *id3v2 = mpeg->ID3v2Tag(false)) {
        const unsigned int major_version = id3v2->header()->majorVersion();
        if(major_version == 2) {
            return false;
        }
        if(major_version == 3) {
            version = TagLib::ID3v2::v3;
        }
    }
    return mpeg->save(
        tag_types,
        TagLib::File::StripNone,
        version,
        TagLib::File::DoNotDuplicate
    );
}

bool HasUnsupportedID3v22(const TagLib::FileRef &file) {
    auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file());
    if(mpeg == nullptr) {
        return false;
    }
    TagLib::ID3v2::Tag *id3v2 = mpeg->ID3v2Tag(false);
    return id3v2 != nullptr && id3v2->header()->majorVersion() == 2;
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
        ATContentProbeResult content;
        if(!ContentMatchesExtension(path, false, content)) {
            SetError(result, ATStatusUnreadable, "音频内容与扩展名不匹配或格式不受支持");
            return result;
        }
        if(IsFooterBearingMPEG(content)) {
            SetError(result, ATStatusUnreadable, "不支持读取带 ID3v2.4 footer 的 MP3");
            return result;
        }
        if(content.container == ATContainer::RawADTS) {
            SetError(result, ATStatusUnreadable, "原始 AAC/ADTS 不包含受支持的标签容器");
            return result;
        }

        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!IsUsableFileRef(file, false)) {
            SetError(result, ATStatusUnreadable, "无法打开或识别音频文件");
            return result;
        }

        const TagLib::Tag *tag = file.tag();
        if(tag == nullptr) {
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
        if(path == nullptr || path[0] == '\0' || ::access(path, W_OK) != 0) {
            return false;
        }

        ATContentProbeResult content;
        if(!ContentMatchesExtension(path, true, content) || IsFooterBearingMPEG(content)) {
            return false;
        }

        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        return IsUsableFileRef(file, true) && !HasUnsupportedID3v22(file);
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
        ATContentProbeResult content;
        if(!ContentMatchesExtension(path, true, content)) {
            SetError(result, ATStatusNotWritable, "音频内容与扩展名不匹配或格式不支持写入");
            return result;
        }
        if(IsFooterBearingMPEG(content)) {
            SetError(result, ATStatusNotWritable, "不支持写入带 ID3v2.4 footer 的 MP3");
            return result;
        }

        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!IsUsableFileRef(file, true)) {
            SetError(result, ATStatusNotWritable, "音频文件不可写或音频属性无效");
            return result;
        }
        if(HasUnsupportedID3v22(file)) {
            SetError(result, ATStatusNotWritable, "不支持写入 ID3v2.2 MP3");
            return result;
        }

        TagLib::Tag *tag = file.tag();
        if(tag == nullptr) {
            SetError(result, ATStatusMissingTag, "音频文件不包含可写标签");
            return result;
        }

        const bool changes_artist = artist_or_null != nullptr;
        const bool changes_album = album_or_null != nullptr;
        const TagLib::PropertyMap properties_before = file.file()->properties();
        const std::string non_target_before = CanonicalPropertyMap(
            properties_before,
            changes_artist,
            changes_album
        );
        const std::vector<std::string> unsupported_before = CanonicalUnsupportedData(
            properties_before.unsupportedData()
        );

        if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file())) {
            RetainNonstandardLegacyID3v23YearFrames(*mpeg);
            RetainStandaloneLegacyID3v23TimeFrames(*mpeg);
            if(changes_artist) {
                tag->setArtist(TagLib::String(artist_or_null, TagLib::String::UTF8));
            }
            if(changes_album) {
                tag->setAlbum(TagLib::String(album_or_null, TagLib::String::UTF8));
            }
        } else {
            TagLib::PropertyMap updated_properties = properties_before;
            if(changes_artist) {
                updated_properties.replace(
                    "ARTIST",
                    TagLib::StringList(
                        TagLib::String(artist_or_null, TagLib::String::UTF8)
                    )
                );
            }
            if(changes_album) {
                updated_properties.replace(
                    "ALBUM",
                    TagLib::StringList(
                        TagLib::String(album_or_null, TagLib::String::UTF8)
                    )
                );
            }
            if(!file.file()->setProperties(updated_properties).isEmpty()) {
                SetError(result, ATStatusSaveFailed, "目标标签无法写入当前音频格式");
                return result;
            }
        }

        if(!SaveMetadataFile(file)) {
            SetError(result, ATStatusSaveFailed, "TagLib 保存音频标签失败");
            return result;
        }

        // TagLib writes through a buffered FILE*. Release the writer before reopening
        // the path, otherwise large tags can be verified against partially flushed data.
        file = TagLib::FileRef();

        const TagLib::FileRef saved_file(path, true, TagLib::AudioProperties::Accurate);
        if(saved_file.isNull() || saved_file.file() == nullptr) {
            SetError(result, ATStatusSaveFailed, "保存后无法重新打开音频文件");
            return result;
        }
        if(!saved_file.file()->isValid()) {
            SetError(result, ATStatusSaveFailed, "保存后音频文件结构无效");
            return result;
        }
        if(saved_file.tag() == nullptr) {
            SetError(result, ATStatusSaveFailed, "保存后无法重新读取音频标签");
            return result;
        }
        if(!HasSaneAudioProperties(saved_file)) {
            SetError(result, ATStatusSaveFailed, "保存后音频属性无效");
            return result;
        }
        const TagLib::PropertyMap properties_after = saved_file.file()->properties();
        const std::string non_target_after = CanonicalPropertyMap(
            properties_after,
            changes_artist,
            changes_album
        );
        if(non_target_after != non_target_before) {
            SetError(result, ATStatusSaveFailed, "保存改变了非目标标签，已拒绝提交");
            return result;
        }

        const std::vector<std::string> unsupported_after = CanonicalUnsupportedData(
            properties_after.unsupportedData()
        );
        if(unsupported_after != unsupported_before) {
            SetError(result, ATStatusSaveFailed, "保存改变了无法识别的标签结构，已拒绝提交");
            return result;
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
