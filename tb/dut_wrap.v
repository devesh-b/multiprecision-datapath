// Wrappers presenting the plain interface, so the testbench does not have to
// know which designs expose the `prod` observation port.
`timescale 1ns/1ps

module dut_split (
  input wire clk, rst, en, sgn, input wire [1:0] mode,
  input wire [15:0] a, b, output wire [47:0] acc);
  mpmac_split u (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
                 .a(a), .b(b), .acc(acc));
endmodule

module dut_shared (
  input wire clk, rst, en, sgn, input wire [1:0] mode,
  input wire [15:0] a, b, output wire [47:0] acc);
  mpmac_shared u (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
                  .a(a), .b(b), .acc(acc), .prod());
endmodule
