#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AR_MAGIC "!<arch>\n"
#define AR_MAGIC_SIZE 8
#define AR_HEADER_SIZE 60
#define IOS_SIMULATOR_PLATFORM 7
#define IOS_SIMULATOR_MINOS 0x000e0000u
#define IOS_SIMULATOR_SDK 0x001a0400u

static void adjust_u32(uint32_t *value, uint32_t removed_at, uint32_t removed_size) {
    if (*value >= removed_at + removed_size) {
        *value -= removed_size;
    }
}

static void adjust_u64(uint64_t *value, uint32_t removed_at, uint32_t removed_size) {
    if (*value >= (uint64_t)removed_at + removed_size) {
        *value -= removed_size;
    }
}

static void add_u32(uint32_t *value, uint32_t inserted_at, uint32_t inserted_size) {
    if (*value >= inserted_at) {
        *value += inserted_size;
    }
}

static void add_u64(uint64_t *value, uint32_t inserted_at, uint32_t inserted_size) {
    if (*value >= (uint64_t)inserted_at) {
        *value += inserted_size;
    }
}

static void adjust_load_command(struct load_command *command, uint32_t removed_at, uint32_t removed_size) {
    switch (command->cmd) {
        case LC_SEGMENT_64: {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            adjust_u64(&segment->fileoff, removed_at, removed_size);
            struct section_64 *sections = (struct section_64 *)(segment + 1);
            for (uint32_t i = 0; i < segment->nsects; ++i) {
                adjust_u32(&sections[i].offset, removed_at, removed_size);
                adjust_u32(&sections[i].reloff, removed_at, removed_size);
            }
            break;
        }
        case LC_SEGMENT: {
            struct segment_command *segment = (struct segment_command *)command;
            adjust_u32(&segment->fileoff, removed_at, removed_size);
            struct section *sections = (struct section *)(segment + 1);
            for (uint32_t i = 0; i < segment->nsects; ++i) {
                adjust_u32(&sections[i].offset, removed_at, removed_size);
                adjust_u32(&sections[i].reloff, removed_at, removed_size);
            }
            break;
        }
        case LC_SYMTAB: {
            struct symtab_command *symtab = (struct symtab_command *)command;
            adjust_u32(&symtab->symoff, removed_at, removed_size);
            adjust_u32(&symtab->stroff, removed_at, removed_size);
            break;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *dysymtab = (struct dysymtab_command *)command;
            adjust_u32(&dysymtab->tocoff, removed_at, removed_size);
            adjust_u32(&dysymtab->modtaboff, removed_at, removed_size);
            adjust_u32(&dysymtab->extrefsymoff, removed_at, removed_size);
            adjust_u32(&dysymtab->indirectsymoff, removed_at, removed_size);
            adjust_u32(&dysymtab->extreloff, removed_at, removed_size);
            adjust_u32(&dysymtab->locreloff, removed_at, removed_size);
            break;
        }
        case LC_DATA_IN_CODE:
        case LC_FUNCTION_STARTS:
        case LC_CODE_SIGNATURE:
        case LC_DYLD_EXPORTS_TRIE:
        case LC_DYLD_CHAINED_FIXUPS:
        case LC_LINKER_OPTIMIZATION_HINT: {
            struct linkedit_data_command *data = (struct linkedit_data_command *)command;
            adjust_u32(&data->dataoff, removed_at, removed_size);
            break;
        }
        default:
            break;
    }
}

static void adjust_load_command_for_insert(struct load_command *command,
                                           uint32_t inserted_at,
                                           uint32_t inserted_size) {
    switch (command->cmd) {
        case LC_SEGMENT_64: {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            add_u64(&segment->fileoff, inserted_at, inserted_size);
            struct section_64 *sections = (struct section_64 *)(segment + 1);
            for (uint32_t i = 0; i < segment->nsects; ++i) {
                add_u32(&sections[i].offset, inserted_at, inserted_size);
                add_u32(&sections[i].reloff, inserted_at, inserted_size);
            }
            break;
        }
        case LC_SEGMENT: {
            struct segment_command *segment = (struct segment_command *)command;
            add_u32(&segment->fileoff, inserted_at, inserted_size);
            struct section *sections = (struct section *)(segment + 1);
            for (uint32_t i = 0; i < segment->nsects; ++i) {
                add_u32(&sections[i].offset, inserted_at, inserted_size);
                add_u32(&sections[i].reloff, inserted_at, inserted_size);
            }
            break;
        }
        case LC_SYMTAB: {
            struct symtab_command *symtab = (struct symtab_command *)command;
            add_u32(&symtab->symoff, inserted_at, inserted_size);
            add_u32(&symtab->stroff, inserted_at, inserted_size);
            break;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *dysymtab = (struct dysymtab_command *)command;
            add_u32(&dysymtab->tocoff, inserted_at, inserted_size);
            add_u32(&dysymtab->modtaboff, inserted_at, inserted_size);
            add_u32(&dysymtab->extrefsymoff, inserted_at, inserted_size);
            add_u32(&dysymtab->indirectsymoff, inserted_at, inserted_size);
            add_u32(&dysymtab->extreloff, inserted_at, inserted_size);
            add_u32(&dysymtab->locreloff, inserted_at, inserted_size);
            break;
        }
        case LC_DATA_IN_CODE:
        case LC_FUNCTION_STARTS:
        case LC_CODE_SIGNATURE:
        case LC_DYLD_EXPORTS_TRIE:
        case LC_DYLD_CHAINED_FIXUPS:
        case LC_LINKER_OPTIMIZATION_HINT: {
            struct linkedit_data_command *data = (struct linkedit_data_command *)command;
            add_u32(&data->dataoff, inserted_at, inserted_size);
            break;
        }
        default:
            break;
    }
}

static int has_build_version(const uint8_t *input, uint32_t header_size,
                             uint32_t ncmds, uint32_t sizeofcmds,
                             uint32_t *build_version_offset) {
    uint32_t command_offset = header_size;
    for (uint32_t i = 0; i < ncmds; ++i) {
        if ((uint64_t)command_offset + sizeof(struct load_command) >
            (uint64_t)header_size + sizeofcmds) {
            return -1;
        }
        const struct load_command *command =
            (const struct load_command *)(input + command_offset);
        if (command->cmdsize < sizeof(struct load_command) ||
            (uint64_t)command_offset + command->cmdsize >
                (uint64_t)header_size + sizeofcmds) {
            return -1;
        }
        if (command->cmd == LC_BUILD_VERSION) {
            if (command->cmdsize < sizeof(struct build_version_command)) return -1;
            if (build_version_offset) *build_version_offset = command_offset;
            return 1;
        }
        command_offset += command->cmdsize;
    }
    return 0;
}

static int add_simulator_build_version(const uint8_t *input, size_t input_size,
                                       uint32_t header_size, uint32_t ncmds,
                                       uint32_t sizeofcmds, uint8_t **output,
                                       size_t *output_size) {
    const uint32_t command_size = sizeof(struct build_version_command);
    const uint32_t inserted_at = header_size + sizeofcmds;
    if (inserted_at > input_size) return -1;

    size_t result_size = input_size + command_size;
    uint8_t *result = (uint8_t *)malloc(result_size);
    if (!result) return -1;
    memcpy(result, input, inserted_at);
    struct build_version_command *build =
        (struct build_version_command *)(result + inserted_at);
    memset(build, 0, command_size);
    build->cmd = LC_BUILD_VERSION;
    build->cmdsize = command_size;
    build->platform = IOS_SIMULATOR_PLATFORM;
    build->minos = IOS_SIMULATOR_MINOS;
    build->sdk = IOS_SIMULATOR_SDK;
    memcpy(result + inserted_at + command_size, input + inserted_at,
           input_size - inserted_at);

    if (input[0] == (uint8_t)(MH_MAGIC_64 & 0xff)) {
        struct mach_header_64 *header = (struct mach_header_64 *)result;
        header->ncmds = ncmds + 1;
        header->sizeofcmds = sizeofcmds + command_size;
    } else {
        struct mach_header *header = (struct mach_header *)result;
        header->ncmds = ncmds + 1;
        header->sizeofcmds = sizeofcmds + command_size;
    }

    uint32_t command_offset = header_size;
    for (uint32_t i = 0; i < ncmds + 1; ++i) {
        struct load_command *command =
            (struct load_command *)(result + command_offset);
        adjust_load_command_for_insert(command, inserted_at, command_size);
        command_offset += command->cmdsize;
    }
    *output = result;
    *output_size = result_size;
    return 1;
}

static int normalize_macho(const uint8_t *input, size_t input_size,
                           uint8_t **output, size_t *output_size) {
    if (input_size < sizeof(struct mach_header)) {
        return 0;
    }

    uint32_t magic = *(const uint32_t *)input;
    uint32_t header_size;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    if (magic == MH_MAGIC_64) {
        if (input_size < sizeof(struct mach_header_64)) return 0;
        const struct mach_header_64 *header = (const struct mach_header_64 *)input;
        header_size = sizeof(*header);
        ncmds = header->ncmds;
        sizeofcmds = header->sizeofcmds;
    } else if (magic == MH_MAGIC) {
        const struct mach_header *header = (const struct mach_header *)input;
        header_size = sizeof(*header);
        ncmds = header->ncmds;
        sizeofcmds = header->sizeofcmds;
    } else {
        return 0;
    }

    if ((uint64_t)header_size + sizeofcmds > input_size) {
        return -1;
    }

    uint32_t command_offset = header_size;
    uint32_t removed_at = 0;
    uint32_t removed_size = 0;
    for (uint32_t i = 0; i < ncmds; ++i) {
        if ((uint64_t)command_offset + sizeof(struct load_command) > input_size) {
            return -1;
        }
        const struct load_command *command =
            (const struct load_command *)(input + command_offset);
        if (command->cmdsize < sizeof(struct load_command) ||
            (uint64_t)command_offset + command->cmdsize > input_size) {
            return -1;
        }
        if (command->cmd == LC_VERSION_MIN_IPHONEOS) {
            removed_at = command_offset;
            removed_size = command->cmdsize;
            break;
        }
        command_offset += command->cmdsize;
    }

    uint8_t *normalized = NULL;
    size_t normalized_size = input_size;
    uint32_t normalized_ncmds = ncmds;
    uint32_t normalized_sizeofcmds = sizeofcmds;
    if (removed_size != 0) {
        if (removed_size > input_size || sizeofcmds < removed_size) return -1;
        normalized_size = input_size - removed_size;
        normalized = (uint8_t *)malloc(normalized_size);
        if (!normalized) return -1;
        memcpy(normalized, input, removed_at);
        memcpy(normalized + removed_at, input + removed_at + removed_size,
               input_size - removed_at - removed_size);
        normalized_ncmds = ncmds - 1;
        normalized_sizeofcmds = sizeofcmds - removed_size;
        if (magic == MH_MAGIC_64) {
            struct mach_header_64 *header = (struct mach_header_64 *)normalized;
            header->ncmds = normalized_ncmds;
            header->sizeofcmds = normalized_sizeofcmds;
        } else {
            struct mach_header *header = (struct mach_header *)normalized;
            header->ncmds = normalized_ncmds;
            header->sizeofcmds = normalized_sizeofcmds;
        }
        command_offset = header_size;
        for (uint32_t i = 0; i < normalized_ncmds; ++i) {
            struct load_command *command =
                (struct load_command *)(normalized + command_offset);
            adjust_load_command(command, removed_at, removed_size);
            command_offset += command->cmdsize;
        }
    } else {
        normalized = (uint8_t *)malloc(input_size);
        if (!normalized) return -1;
        memcpy(normalized, input, input_size);
    }

    uint32_t build_offset = 0;
    int build_result = has_build_version(normalized, header_size,
                                         normalized_ncmds,
                                         normalized_sizeofcmds, &build_offset);
    if (build_result < 0) {
        free(normalized);
        return -1;
    }
    if (build_result > 0) {
        struct build_version_command *build =
            (struct build_version_command *)(normalized + build_offset);
        build->platform = IOS_SIMULATOR_PLATFORM;
        *output = normalized;
        *output_size = normalized_size;
        return 1;
    }

    uint8_t *with_platform = NULL;
    size_t with_platform_size = 0;
    int add_result = add_simulator_build_version(
        normalized, normalized_size, header_size, normalized_ncmds,
        normalized_sizeofcmds, &with_platform, &with_platform_size);
    free(normalized);
    if (add_result < 0) return -1;
    *output = with_platform;
    *output_size = with_platform_size;
    return 1;
}

static int parse_decimal(const char *field, size_t length, size_t *value) {
    char buffer[32];
    if (length >= sizeof(buffer)) return -1;
    memcpy(buffer, field, length);
    buffer[length] = '\0';
    char *end = NULL;
    unsigned long parsed = strtoul(buffer, &end, 10);
    if (end == buffer) return -1;
    *value = (size_t)parsed;
    return 0;
}

static int write_archive_header(uint8_t *header, size_t size) {
    char field[11];
    int written = snprintf(field, sizeof(field), "%zu", size);
    if (written < 0 || written > 10) return -1;
    memset(header + 48, ' ', 10);
    memcpy(header + 48, field, (size_t)written);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s input.a output.a\n", argv[0]);
        return 2;
    }

    FILE *input = fopen(argv[1], "rb");
    FILE *output = fopen(argv[2], "wb");
    if (!input || !output) {
        perror("normalize_archive_macho");
        if (input) fclose(input);
        if (output) fclose(output);
        return 1;
    }

    char archive_magic[AR_MAGIC_SIZE];
    if (fread(archive_magic, 1, AR_MAGIC_SIZE, input) != AR_MAGIC_SIZE ||
        memcmp(archive_magic, AR_MAGIC, AR_MAGIC_SIZE) != 0) {
        fprintf(stderr, "normalize_archive_macho: not an ar archive\n");
        fclose(input);
        fclose(output);
        return 1;
    }
    fwrite(archive_magic, 1, AR_MAGIC_SIZE, output);

    uint8_t header[AR_HEADER_SIZE];
    while (fread(header, 1, AR_HEADER_SIZE, input) == AR_HEADER_SIZE) {
        if (header[58] != '`' || header[59] != '\n') {
            fprintf(stderr, "normalize_archive_macho: invalid member header\n");
            fclose(input);
            fclose(output);
            return 1;
        }
        size_t member_size;
        if (parse_decimal((const char *)header + 48, 10, &member_size) != 0) {
            fprintf(stderr, "normalize_archive_macho: invalid member size\n");
            fclose(input);
            fclose(output);
            return 1;
        }

        uint8_t *member = (uint8_t *)malloc(member_size ? member_size : 1);
        if (!member || fread(member, 1, member_size, input) != member_size) {
            fprintf(stderr, "normalize_archive_macho: truncated member\n");
            free(member);
            fclose(input);
            fclose(output);
            return 1;
        }

        size_t data_offset = 0;
        if (header[0] == '#' && header[1] == '1' && header[2] == '/') {
            size_t extended_length;
            if (parse_decimal((const char *)header + 3, 13, &extended_length) != 0 ||
                extended_length > member_size) {
                free(member);
                fclose(input);
                fclose(output);
                return 1;
            }
            data_offset = extended_length;
        }

        uint8_t *normalized = NULL;
        size_t normalized_size = 0;
        int result = normalize_macho(member + data_offset,
                                     member_size - data_offset,
                                     &normalized, &normalized_size);
        if (result < 0) {
            fprintf(stderr, "normalize_archive_macho: invalid Mach-O member\n");
            free(member);
            fclose(input);
            fclose(output);
            return 1;
        }

        size_t output_member_size = member_size;
        if (result > 0) {
            output_member_size = data_offset + normalized_size;
            if (write_archive_header(header, output_member_size) != 0) {
                free(normalized);
                free(member);
                fclose(input);
                fclose(output);
                return 1;
            }
        }
        fwrite(header, 1, AR_HEADER_SIZE, output);
        if (result > 0) {
            fwrite(member, 1, data_offset, output);
            fwrite(normalized, 1, normalized_size, output);
            free(normalized);
        } else {
            fwrite(member, 1, member_size, output);
        }
        if (output_member_size & 1) fputc('\n', output);
        free(member);
        if (member_size & 1) fgetc(input);
    }

    int ok = ferror(input) ? 0 : 1;
    fclose(input);
    if (fclose(output) != 0) ok = 0;
    return ok ? 0 : 1;
}
