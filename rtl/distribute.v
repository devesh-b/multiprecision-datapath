// Distributing a multiply over an add:  a*b + a*c  ->  a*(b+c)
//
// Textbook algebra, and false in hardware unless you say how wide the
// intermediate sum is. This is the concrete form of the "sufficient condition"
// column in Coward, Constantinides & Drane (ARITH 2022, Table II): their
// rewrites carry bitwidth side-conditions precisely because the identity is
// about integers while the circuit is about fixed-width bitvectors.
//
// Three implementations of the same integer expression:
//   dist_expanded  two multiplies, no intermediate sum  -- the reference
//   dist_wide      one multiply, intermediate held in W+1 bits  -- always equal
//   dist_narrow    one multiply, intermediate truncated to W    -- equal ONLY
//                  when b+c does not overflow W bits
//
// The narrow version is the cheaper circuit, which is exactly why the condition
// matters: a rewriter that applies it unconditionally produces a smaller design
// that is wrong on a subset of inputs no directed test is likely to visit.
`timescale 1ns/1ps

module dist_expanded #(parameter integer W = 8) (
  input  wire [W-1:0] a, b, c,
  output wire [2*W:0] y
);
  assign y = a*b + a*c;                 // widened by the context, no truncation
endmodule

module dist_wide #(parameter integer W = 8) (
  input  wire [W-1:0] a, b, c,
  output wire [2*W:0] y
);
  wire [W:0] s = {1'b0, b} + {1'b0, c}; // W+1 bits: cannot overflow
  assign y = a * s;
endmodule

module dist_narrow #(parameter integer W = 8) (
  input  wire [W-1:0] a, b, c,
  output wire [2*W:0] y
);
  wire [W-1:0] s = b + c;               // W bits: b+c wraps when it overflows
  assign y = a * s;
endmodule
