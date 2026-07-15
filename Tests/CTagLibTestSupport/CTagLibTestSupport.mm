#include "CTagLibTestSupport.h"

#include <taglib/fileref.h>
#include <taglib/id3v2tag.h>
#include <taglib/mpegfile.h>
#include <taglib/tbytevector.h>
#include <taglib/tpropertymap.h>
#include <taglib/tstring.h>
#include <taglib/tstringlist.h>
#include <taglib/tvariant.h>
#include <taglib/unknownframe.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

namespace {
char *Duplicate(const std::string &value) {
    return ::strdup(value.c_str());
}

bool Usable(const TagLib::FileRef &file) {
    return !file.isNull() && file.file() != nullptr && file.file()->isValid() && file.tag() != nullptr;
}

std::string UTF8(const TagLib::String &value) {
    return value.to8Bit(true);
}

void AppendLengthPrefixed(std::ostringstream &stream, const std::string &value) {
    stream << value.size() << ':' << value;
}

std::string CanonicalProperties(
    const TagLib::PropertyMap &properties,
    bool exclude_artist,
    bool exclude_album
) {
    std::vector<std::pair<std::string, std::vector<std::string>>> entries;
    for(auto iterator = properties.cbegin(); iterator != properties.cend(); ++iterator) {
        const std::string key = UTF8(iterator->first.upper());
        if((exclude_artist && key == "ARTIST") || (exclude_album && key == "ALBUM")) {
            continue;
        }
        std::vector<std::string> values;
        for(const auto &value : iterator->second) {
            values.push_back(UTF8(value));
        }
        entries.emplace_back(key, values);
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

std::string CanonicalStrings(const TagLib::StringList &values) {
    std::vector<std::string> canonical;
    for(const auto &value : values) {
        canonical.push_back(UTF8(value));
    }
    std::sort(canonical.begin(), canonical.end());

    std::ostringstream stream;
    for(const auto &value : canonical) {
        AppendLengthPrefixed(stream, value);
        stream << '\n';
    }
    return stream.str();
}

TagLib::StringList Values(std::initializer_list<const char *> values) {
    TagLib::StringList result;
    for(const char *value : values) {
        result.append(TagLib::String(value, TagLib::String::UTF8));
    }
    return result;
}

bool AddPicture(TagLib::FileRef &file) {
    static const unsigned char png[] = {
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
        0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    };

    TagLib::VariantMap picture;
    picture["data"] = TagLib::ByteVector(
        reinterpret_cast<const char *>(png),
        sizeof(png)
    );
    picture["mimeType"] = TagLib::String("image/png", TagLib::String::UTF8);
    picture["pictureType"] = TagLib::String("Front Cover", TagLib::String::UTF8);
    picture["description"] = TagLib::String("Preservation regression", TagLib::String::UTF8);

    TagLib::List<TagLib::VariantMap> pictures;
    pictures.append(picture);
    return file.setComplexProperties("PICTURE", pictures);
}

bool AddUnknownMP3Frame(TagLib::FileRef &file) {
    auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file());
    if(mpeg == nullptr) {
        return false;
    }
    TagLib::ID3v2::Tag *tag = mpeg->ID3v2Tag(true);
    if(tag == nullptr) {
        return false;
    }

    TagLib::ByteVector frame("XZZZ", 4);
    TagLib::ByteVector size(4, 0);
    size[3] = 22;
    frame.append(size);
    frame.append(TagLib::ByteVector(2, 0));
    frame.append(TagLib::ByteVector("opaque-regression-data", 22));
    tag->addFrame(new TagLib::ID3v2::UnknownFrame(frame));
    return true;
}
}  // namespace

bool ATTestClearMetadata(const char *path) {
    try {
        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!Usable(file)) {
            return false;
        }
        const TagLib::PropertyMap rejected = file.setProperties(TagLib::PropertyMap());
        if(!rejected.isEmpty()) {
            return false;
        }
        for(const auto &key : file.complexPropertyKeys()) {
            if(!file.setComplexProperties(key, {})) {
                return false;
            }
        }
        return file.save();
    }
    catch(...) {
        return false;
    }
}

bool ATTestTagIsEmpty(const char *path) {
    try {
        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        return Usable(file) && file.tag()->isEmpty();
    }
    catch(...) {
        return false;
    }
}

bool ATTestSeedRichMetadata(const char *path, bool include_unknown_mp3_frame) {
    try {
        TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!Usable(file)) {
            return false;
        }

        TagLib::PropertyMap properties = file.properties();
        properties.replace("TITLE", Values({"Fixture Title"}));
        properties.replace("ARTIST", Values({"Original Artist", "Second Artist"}));
        properties.replace("ALBUM", Values({"Original Album"}));
        properties.replace("GENRE", Values({"Rock"}));
        properties.replace("DATE", Values({"2024"}));
        properties.replace("TRACKNUMBER", Values({"7"}));
        properties.replace("LYRICS", Values({"Preserve these lyrics"}));
        properties.replace("COMMENT", Values({"Preserve this comment"}));
        if(!file.setProperties(properties).isEmpty()) {
            return false;
        }
        if(!AddPicture(file)) {
            return false;
        }
        if(include_unknown_mp3_frame && !AddUnknownMP3Frame(file)) {
            return false;
        }
        return file.save();
    }
    catch(...) {
        return false;
    }
}

char *ATTestPropertyValues(const char *path, const char *key) {
    try {
        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!Usable(file) || key == nullptr) {
            return nullptr;
        }
        const TagLib::PropertyMap properties = file.properties();
        const auto iterator = properties.find(TagLib::String(key, TagLib::String::UTF8).upper());
        if(iterator == properties.end()) {
            return Duplicate("");
        }
        return Duplicate(CanonicalStrings(iterator->second));
    }
    catch(...) {
        return nullptr;
    }
}

char *ATTestCanonicalProperties(const char *path, bool exclude_artist, bool exclude_album) {
    try {
        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!Usable(file)) {
            return nullptr;
        }
        return Duplicate(CanonicalProperties(file.properties(), exclude_artist, exclude_album));
    }
    catch(...) {
        return nullptr;
    }
}

char *ATTestUnsupportedData(const char *path) {
    try {
        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!Usable(file)) {
            return nullptr;
        }
        return Duplicate(CanonicalStrings(file.properties().unsupportedData()));
    }
    catch(...) {
        return nullptr;
    }
}

size_t ATTestComplexPropertyCount(const char *path, const char *key) {
    try {
        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        if(!Usable(file) || key == nullptr) {
            return 0;
        }
        return file.complexProperties(TagLib::String(key, TagLib::String::UTF8)).size();
    }
    catch(...) {
        return 0;
    }
}

bool ATTestHasID3v2Frame(const char *path, const char *identifier) {
    try {
        const TagLib::FileRef file(path, true, TagLib::AudioProperties::Accurate);
        auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file());
        if(mpeg == nullptr || identifier == nullptr || std::strlen(identifier) != 4) {
            return false;
        }
        const TagLib::ID3v2::Tag *tag = mpeg->ID3v2Tag();
        return tag != nullptr && !tag->frameList(TagLib::ByteVector(identifier, 4)).isEmpty();
    }
    catch(...) {
        return false;
    }
}

void ATTestFreeString(char *value) {
    std::free(value);
}
