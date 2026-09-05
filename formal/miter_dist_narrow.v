// Unconditional, with the narrow intermediate: this MUST fail, and the
// counterexample is the point -- it names a case the rewrite cannot cover.
module miter_dist_narrow (input [3:0] a, b, c);
  wire [8:0] y0, y1;
  dist_expanded #(4) u0 (.a(a), .b(b), .c(c), .y(y0));
  dist_narrow   #(4) u1 (.a(a), .b(b), .c(c), .y(y1));
  always @* assert (y0 == y1);
endmodule
