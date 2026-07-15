#include "CTagLibBridge.h"

#include <taglib/audioproperties.h>
#include <taglib/fileref.h>
#include <taglib/tag.h>
#include <taglib/tfile.h>
#include <taglib/tstring.h>

#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>

namespace {
constexpr int32_t ATStatusInvalidPath = 1;
constexpr int32_t ATStatusUnreadable = 2;
constexpr int32_t ATStatusMissingTag = 3;
constexpr int32_t ATStatusAllocationFailure = 4;
constexpr int32_t ATStatusUnexpectedFailure = 5;
constexpr int32_t ATStatusNotWritable = 6;
constexpr int32_t ATStatusSaveFailed = 7;

ATReadResult EmptyReadResult() {
    return ATReadResult{0, nullptr, nullptr, nullptr, 0, nullptr};
}

ATWriteResult EmptyWriteResult() {
    return ATWriteResult{0, nullptr};
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

bool HasRawAACExtension(const char *path) {
    const std::string value(path);
    if(value.size() < 4) {
        return false;
    }

    std::string extension = value.substr(value.size() - 4);
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return extension == ".aac";
}

bool IsWritableFileRef(const TagLib::FileRef &file) {
    if(file.isNull() || file.tag() == nullptr) {
        return false;
    }

    const TagLib::File *underlyingFile = file.file();
    return underlyingFile != nullptr
        && underlyingFile->isValid()
        && !underlyingFile->readOnly();
}
}  // namespace

ATReadResult ATReadMetadata(const char *path) {
    ATReadResult result = EmptyReadResult();

    if(path == nullptr || path[0] == '\0') {
        SetError(result, ATStatusInvalidPath, "音频文件路径为空");
        return result;
    }

    try {
        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(file.isNull()) {
            SetError(result, ATStatusUnreadable, "无法打开或识别音频文件");
            return result;
        }

        const TagLib::Tag *tag = file.tag();
        if(tag == nullptr || tag->isEmpty()) {
            SetError(result, ATStatusMissingTag, "音频文件不包含可读取的标签");
            return result;
        }

        if(!CopyTagStrings(*tag, result)) {
            ATFreeReadResult(&result);
            SetError(result, ATStatusAllocationFailure, "读取音频标签时内存分配失败");
            return result;
        }

        const TagLib::AudioProperties *properties = file.audioProperties();
        if(properties != nullptr) {
            result.duration_seconds = static_cast<double>(properties->lengthInMilliseconds()) / 1000.0;
        }

        return result;
    }
    catch(const std::exception &) {
        ATFreeReadResult(&result);
        SetError(result, ATStatusUnexpectedFailure, "读取音频标签时发生内部错误");
        return result;
    }
    catch(...) {
        ATFreeReadResult(&result);
        SetError(result, ATStatusUnexpectedFailure, "读取音频标签时发生未知错误");
        return result;
    }
}

void ATFreeReadResult(ATReadResult *result) {
    if(result == nullptr) {
        return;
    }

    std::free(result->title);
    std::free(result->artist);
    std::free(result->album);
    std::free(result->error_message);
    *result = EmptyReadResult();
}

bool ATCanWriteMetadata(const char *path) {
    if(path == nullptr || path[0] == '\0' || HasRawAACExtension(path)
        || ::access(path, W_OK) != 0) {
        return false;
    }

    try {
        const TagLib::FileRef file(path, false);
        return IsWritableFileRef(file);
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

    if(path == nullptr || path[0] == '\0') {
        SetError(result, ATStatusInvalidPath, "音频文件路径为空");
        return result;
    }

    if(HasRawAACExtension(path)) {
        SetError(result, ATStatusNotWritable, "不支持写入原始 AAC 文件标签");
        return result;
    }

    if(::access(path, W_OK) != 0) {
        SetError(result, ATStatusNotWritable, "音频文件不可写");
        return result;
    }

    try {
        TagLib::FileRef file(path, false);
        if(file.isNull() || file.file() == nullptr || !file.file()->isValid()) {
            SetError(result, ATStatusUnreadable, "无法打开或识别可写音频文件");
            return result;
        }
        if(file.file()->readOnly()) {
            SetError(result, ATStatusNotWritable, "音频文件不可写");
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
    catch(const std::exception &) {
        SetError(result, ATStatusUnexpectedFailure, "保存音频标签时发生内部错误");
        return result;
    }
    catch(...) {
        SetError(result, ATStatusUnexpectedFailure, "保存音频标签时发生未知错误");
        return result;
    }
}

void ATFreeWriteResult(ATWriteResult *result) {
    if(result == nullptr) {
        return;
    }

    std::free(result->error_message);
    *result = EmptyWriteResult();
}
