#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void adjust_offset(uint32_t *value, uint32_t removed_at, uint32_t removed_size) {
    if (*value >= removed_at + removed_size) {
        *value -= removed_size;
    }
}

static void adjust_load_command(struct load_command *command, uint32_t removed_at, uint32_t removed_size) {
    switch (command->cmd) {
        case LC_SEGMENT_64: {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            adjust_offset((uint32_t *)&segment->fileoff, removed_at, removed_size);
            struct section_64 *sections = (struct section_64 *)(segment + 1);
            for (uint32_t i = 0; i < segment->nsects; ++i) {
                adjust_offset(&sections[i].offset, removed_at, removed_size);
                adjust_offset(&sections[i].reloff, removed_at, removed_size);
            }
            break;
        }
        case LC_SEGMENT: {
            struct segment_command *segment = (struct segment_command *)command;
            adjust_offset(&segment->fileoff, removed_at, removed_size);
            struct section *sections = (struct section *)(segment + 1);
            for (uint32_t i = 0; i < segment->nsects; ++i) {
                adjust_offset(&sections[i].offset, removed_at, removed_size);
                adjust_offset(&sections[i].reloff, removed_at, removed_size);
            }
            break;
        }
        case LC_SYMTAB: {
            struct symtab_command *symtab = (struct symtab_command *)command;
            adjust_offset(&symtab->symoff, removed_at, removed_size);
            adjust_offset(&symtab->stroff, removed_at, removed_size);
            break;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *dysymtab = (struct dysymtab_command *)command;
            adjust_offset(&dysymtab->tocoff, removed_at, removed_size);
            adjust_offset(&dysymtab->modtaboff, removed_at, removed_size);
            adjust_offset(&dysymtab->extrefsymoff, removed_at, removed_size);
            adjust_offset(&dysymtab->indirectsymoff, removed_at, removed_size);
            adjust_offset(&dysymtab->extreloff, removed_at, removed_size);
            adjust_offset(&dysymtab->locreloff, removed_at, removed_size);
            break;
        }
        case LC_DATA_IN_CODE:
        case LC_FUNCTION_STARTS:
        case LC_CODE_SIGNATURE:
        case LC_DYLD_EXPORTS_TRIE:
        case LC_DYLD_CHAINED_FIXUPS: {
            struct linkedit_data_command *data = (struct linkedit_data_command *)command;
            adjust_offset(&data->dataoff, removed_at, removed_size);
            break;
        }
        case LC_LINKER_OPTIMIZATION_HINT: {
            struct linkedit_data_command *hint = (struct linkedit_data_command *)command;
            adjust_offset(&hint->dataoff, removed_at, removed_size);
            break;
        }
        default:
            break;
    }
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s input.o output.o\n", argv[0]);
        return 2;
    }

    FILE *input = fopen(argv[1], "rb");
    if (!input) {
        perror(argv[1]);
        return 1;
    }
    if (fseek(input, 0, SEEK_END) != 0) {
        fclose(input);
        return 1;
    }
    long input_size = ftell(input);
    if (input_size < (long)sizeof(struct mach_header_64)) {
        fclose(input);
        return 1;
    }
    rewind(input);

    uint8_t *bytes = (uint8_t *)malloc((size_t)input_size);
    if (!bytes || fread(bytes, 1, (size_t)input_size, input) != (size_t)input_size) {
        fclose(input);
        free(bytes);
        return 1;
    }
    fclose(input);

    uint32_t magic = *(uint32_t *)bytes;
    uint32_t header_size;
    uint32_t *ncmds;
    uint32_t *sizeofcmds;
    if (magic == MH_MAGIC_64) {
        struct mach_header_64 *header = (struct mach_header_64 *)bytes;
        header_size = sizeof(*header);
        ncmds = &header->ncmds;
        sizeofcmds = &header->sizeofcmds;
    } else if (magic == MH_MAGIC) {
        struct mach_header *header = (struct mach_header *)bytes;
        header_size = sizeof(*header);
        ncmds = &header->ncmds;
        sizeofcmds = &header->sizeofcmds;
    } else {
        free(bytes);
        return 0;
    }

    uint32_t command_offset = header_size;
    uint32_t removed_at = 0;
    uint32_t removed_size = 0;
    for (uint32_t i = 0; i < *ncmds; ++i) {
        if (command_offset + sizeof(struct load_command) > (uint32_t)input_size) {
            free(bytes);
            return 1;
        }
        struct load_command *command = (struct load_command *)(bytes + command_offset);
        if (command->cmd == LC_VERSION_MIN_IPHONEOS) {
            removed_at = command_offset;
            removed_size = command->cmdsize;
            break;
        }
        command_offset += command->cmdsize;
    }

    if (removed_size == 0) {
        FILE *output = fopen(argv[2], "wb");
        if (!output) {
            free(bytes);
            return 1;
        }
        fwrite(bytes, 1, (size_t)input_size, output);
        fclose(output);
        free(bytes);
        return 0;
    }

    memmove(bytes + removed_at, bytes + removed_at + removed_size,
            (size_t)input_size - removed_at - removed_size);
    *ncmds -= 1;
    *sizeofcmds -= removed_size;

    command_offset = header_size;
    for (uint32_t i = 0; i < *ncmds; ++i) {
        struct load_command *command = (struct load_command *)(bytes + command_offset);
        adjust_load_command(command, removed_at, removed_size);
        command_offset += command->cmdsize;
    }

    FILE *output = fopen(argv[2], "wb");
    if (!output) {
        free(bytes);
        return 1;
    }
    size_t output_size = (size_t)input_size - removed_size;
    int result = fwrite(bytes, 1, output_size, output) == output_size ? 0 : 1;
    fclose(output);
    free(bytes);
    return result;
}
