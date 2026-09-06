module cu(input logic iclk);
  bit [31:0] fetched_instr;
  instr decoded_instr;

  function void throw_error();
    $error("ERROR THROWN");
  endfunction

  function void fetch();
    fetched_instr = mem::mem(regs::pc); 
  endfunction

  function void decode();
    decoded_instr = instr::create(fetched_instr);
  endfunction

  function void execute();
    if (!decoded_instr.execute()) begin
      throw_error();
    end
  endfunction

  always @(posedge iclk) begin
    fetch();
    decode();
    execute();
  end
endmodule
