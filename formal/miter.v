// Miter: assert rca(a,b,cin) === cla(a,b,cin) for ALL inputs. Combinational, depth 1.
module miter (input [7:0] a, b, input cin);
  wire [7:0] s0, s1; wire c0, c1;
  rca #(8) u0 (.a(a), .b(b), .cin(cin), .s(s0), .cout(c0));
  cla #(8) u1 (.a(a), .b(b), .cin(cin), .s(s1), .cout(c1));
  always @* begin
    assert (s0 == s1);
    assert (c0 == c1);
  end
endmodule
