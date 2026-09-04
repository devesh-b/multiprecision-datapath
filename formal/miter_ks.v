module miter_ks (input [7:0] a, b, input cin);
  wire [7:0] s0, s1; wire c0, c1;
  rca #(8) u0 (.a(a), .b(b), .cin(cin), .s(s0), .cout(c0));
  ksa #(8) u1 (.a(a), .b(b), .cin(cin), .s(s1), .cout(c1));
  always @* begin assert (s0 == s1); assert (c0 == c1); end
endmodule
