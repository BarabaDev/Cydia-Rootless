/* Minimal rootless Cydia du helper: supports only the two modes Cydia uses. */

#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include <limits>
#include <string>

static bool Failed(false);

static uint64_t AddSaturated(uint64_t left, uint64_t right) {
    return right > std::numeric_limits<uint64_t>::max() - left ? std::numeric_limits<uint64_t>::max() : left + right;
}

static uint64_t Measure(const std::string &path, bool apparent) {
    struct stat info;
    if (lstat(path.c_str(), &info) != 0) {
        fprintf(stderr, "du: %s: %s\n", path.c_str(), strerror(errno));
        Failed = true;
        return 0;
    }

    uint64_t total(apparent ? static_cast<uint64_t>(info.st_size) : static_cast<uint64_t>(info.st_blocks) * 512ULL);
    if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode))
        return total;

    DIR *directory(opendir(path.c_str()));
    if (directory == NULL) {
        fprintf(stderr, "du: %s: %s\n", path.c_str(), strerror(errno));
        Failed = true;
        return total;
    }
    for (struct dirent *entry(readdir(directory)); entry != NULL; entry = readdir(directory)) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        std::string child(path);
        if (child.empty() || child[child.size() - 1] != '/')
            child += '/';
        child += entry->d_name;
        total = AddSaturated(total, Measure(child, apparent));
    }
    if (closedir(directory) != 0)
        Failed = true;
    return total;
}

int main(int argc, char *argv[]) {
    if (argc != 3 || argv[1] == NULL || argv[2] == NULL) {
        fprintf(stderr, "usage: du -ks path | du -bs path\n");
        return 2;
    }
    bool apparent(false);
    if (strcmp(argv[1], "-bs") == 0 || strcmp(argv[1], "-sb") == 0)
        apparent = true;
    else if (strcmp(argv[1], "-ks") != 0 && strcmp(argv[1], "-sk") != 0) {
        fprintf(stderr, "du: unsupported option: %s\n", argv[1]);
        return 2;
    }

    uint64_t total(Measure(argv[2], apparent));
    if (!apparent)
        total = AddSaturated(total, 1023ULL) / 1024ULL;
    printf("%llu\t%s\n", static_cast<unsigned long long>(total), argv[2]);
    return Failed ? 1 : 0;
}
