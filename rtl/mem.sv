// Unified byte-addressed instruction/data memory (simulation model).
// Reads are asynchronous; stores are performed by cu on the clock edge.
// Misaligned data accesses are supported (RV32I allows this in hardware).
package mem;
  import isa::*;

  localparam int SIZE_BYTES = 64 * 1024;

  bit [7:0] mem_pages[SIZE_BYTES];

  function automatic bit [7:0] byte_at(bit [31:0] addr);
    return (addr < 32'(SIZE_BYTES)) ? mem_pages[addr] : 8'd0;
  endfunction

  function automatic bit [31:0] word_at(bit [31:0] addr);
    return {byte_at(addr + 3), byte_at(addr + 2), byte_at(addr + 1), byte_at(addr)};
  endfunction

  // Out-of-range fetches return 0, which the decoder rejects as illegal.
  function automatic bit [31:0] fetch(bit [31:0] addr);
    return word_at(addr);
  endfunction

  // True if a load/store of 2**width bytes (width = funct3[1:0]) at addr is
  // inside memory.
  function automatic bit access_ok(bit [31:0] addr, bit [1:0] width);
    return addr <= 32'(SIZE_BYTES) - (32'd1 << width);
  endfunction

  function automatic bit [31:0] load(bit [31:0] addr, bit [2:0] funct3);
    bit [31:0] w;
    w = word_at(addr);
    case (funct3)
      FUNCT3_LB:  return {{24{w[7]}},  w[7:0]};
      FUNCT3_LH:  return {{16{w[15]}}, w[15:0]};
      FUNCT3_LW:  return w;
      FUNCT3_LBU: return {24'd0, w[7:0]};
      FUNCT3_LHU: return {16'd0, w[15:0]};
      default:    return 32'd0;
    endcase
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
