package mem;
  bit [7:0] mem_pages[0:255*4];

  function bit[31:0] mem(bit[31:0] addr);
    static bit[31:0] data;
    data = {mem_pages[addr + 3],
            mem_pages[addr + 2],
            mem_pages[addr + 1],
            mem_pages[addr]};

    return data;
  endfunction

  function void read_from_file(string path);
    int fd;
    int bytes_read;

    $display("Reading data from %0s file", path);
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "Cannot open %0s", path);

    bytes_read = $fread(mem_pages, fd);
    $fclose(fd);

    $display("Loaded %0d bytes", bytes_read);
  endfunction
endpackage
