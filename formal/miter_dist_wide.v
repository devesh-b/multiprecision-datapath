// Unconditional: widening the intermediate makes the rewrite always valid.
module miter_dist_wide (input [3:0] a, b, c);
  wire [8:0] y0, y1;
  dist_expanded #(4) u0 (.a(a), .b(b), .c(c), .y(y0));
  dist_wide     #(4) u1 (.a(a), .b(b), .c(c), .y(y1));
  always @* assert (y0 == y1);
endmodule
