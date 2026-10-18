package mem;
  localparam int SIZE_BYTES = 4096;

  bit [7:0] mem_pages[SIZE_BYTES];

  // Out-of-range fetches return 0, which the decoder rejects as illegal.
  function automatic bit [31:0] mem(bit [31:0] addr);
    if (addr > 32'(SIZE_BYTES - 4)) return 32'd0;
    return {mem_pages[addr + 3], mem_pages[addr + 2],
            mem_pages[addr + 1], mem_pages[addr]};
  endfunction

  function automatic void read_from_file(string path);
    int fd;
    int bytes_read;

    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "Cannot open %0s", path);

    bytes_read = $fread(mem_pages, fd);
    if ($fgetc(fd) != -1) $fatal(1, "%0s is larger than %0d bytes of memory", path, SIZE_BYTES);
    $fclose(fd);

    $display("Loaded %0d bytes from %0s", bytes_read, path);
  endfunction
endpackage
