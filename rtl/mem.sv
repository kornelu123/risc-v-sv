package mem;
  bit [7:0] mem_pages[0:11] = {
    8'h30, 8'h00, 8'h00, 8'h13,
    8'h70, 8'h00, 8'h00, 8'h13,
    8'h90, 8'h00, 8'h00, 8'h13
  };

  function bit[31:0] mem(bit[31:0] addr);
    return {mem_pages[addr], mem_pages[addr + 1], mem_pages[addr + 2], mem_pages[addr + 3]};
  endfunction
endpackage
