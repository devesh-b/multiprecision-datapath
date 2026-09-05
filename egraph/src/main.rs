//! Distributivity as a *conditional* e-graph rewrite.
//!
//! `a*b + a*c  ->  a*(b+c)` removes a multiplier, and is unsound in hardware
//! whenever the intermediate `b+c` does not fit the datapath. That is not a
//! hypothetical: `formal/dist_narrow.sby` in this repository finds the
//! counterexample (a=1, b=12, c=4 at W=4, where b+c wraps to 0), and
//! `formal/dist_cond.sby` proves the same circuit correct once the no-overflow
//! condition is assumed.
//!
//! This encodes that condition as a rewrite guard, which is what makes an
//! e-graph optimiser safe to point at a datapath. It is the mechanism behind
//! the "sufficient condition" column of Coward, Constantinides & Drane,
//! *Automatic Datapath Optimization using E-Graphs*, ARITH 2022, Table II.
//!
//! Run with `cargo run --release`.

use egg::{rewrite as rw, *};
use std::collections::HashMap;

define_language! {
    enum Bv {
        Num(i64),
        "*" = Mul([Id; 2]),
        "+" = Add([Id; 2]),
        Var(Symbol),
    }
}

/// Bits needed to hold a value exactly. This is the analysis that carries
/// bitwidth up the expression, the way ARITH 2022 carries it on e-graph edges.
#[derive(Default, Clone)]
struct WidthAnalysis {
    widths: HashMap<Symbol, u32>,
    datapath: u32,
}

impl Analysis<Bv> for WidthAnalysis {
    type Data = u32;

    fn make(egraph: &EGraph<Bv, Self>, enode: &Bv) -> Self::Data {
        let d = |i: &Id| egraph[*i].data;
        match enode {
            Bv::Num(n) => (64 - n.unsigned_abs().leading_zeros()).max(1),
            Bv::Var(s) => *egraph.analysis.widths.get(s).unwrap_or(&32),
            // a sum can carry one bit further than its widest operand
            Bv::Add([a, b]) => d(a).max(d(b)) + 1,
            // a product needs the sum of its operands' widths
            Bv::Mul([a, b]) => d(a) + d(b),
        }
    }

    fn merge(&mut self, to: &mut Self::Data, from: Self::Data) -> DidMerge {
        // Both are valid upper bounds, so the tighter one is still valid.
        let old = *to;
        *to = (*to).min(from);
        DidMerge(*to != old, *to != from)
    }
}

/// The side-condition: the factored form materialises `b+c`, so that sum has to
/// fit the datapath. Without this guard the rewrite is the one the solver
/// refutes.
fn sum_fits(b: &'static str, c: &'static str)
    -> impl Fn(&mut EGraph<Bv, WidthAnalysis>, Id, &Subst) -> bool
{
    let b: Var = b.parse().unwrap();
    let c: Var = c.parse().unwrap();
    move |egraph, _, subst| {
        let need = egraph[subst[b]].data.max(egraph[subst[c]].data) + 1;
        need <= egraph.analysis.datapath
    }
}

fn rules(guarded: bool) -> Vec<Rewrite<Bv, WidthAnalysis>> {
    let mut r = vec![
        rw!("comm-add"; "(+ ?a ?b)" => "(+ ?b ?a)"),
        rw!("comm-mul"; "(* ?a ?b)" => "(* ?b ?a)"),
    ];
    if guarded {
        r.push(rw!("factor"; "(+ (* ?a ?b) (* ?a ?c))" => "(* ?a (+ ?b ?c))"
                   if sum_fits("?b", "?c")));
    } else {
        // the same rewrite with its side-condition removed: what a naive
        // optimiser does, and what the solver refutes
        r.push(rw!("factor-unguarded"; "(+ (* ?a ?b) (* ?a ?c))" => "(* ?a (+ ?b ?c))"));
    }
    r
}

/// Area proxy: a multiplier costs far more than an adder. Deliberately crude --
/// ARITH 2022 uses a two-input-gate estimate parameterised by operand width;
/// this only needs to rank one multiply against two.
struct AreaCost;
impl CostFunction<Bv> for AreaCost {
    type Cost = usize;
    fn cost<C>(&mut self, enode: &Bv, mut costs: C) -> usize
    where C: FnMut(Id) -> usize {
        let here = match enode {
            Bv::Mul(_) => 100,
            Bv::Add(_) => 10,
            _ => 0,
        };
        enode.fold(here, |sum, id| sum + costs(id))
    }
}

fn optimise(expr_s: &str, widths: &[(&str, u32)], datapath: u32, guarded: bool)
    -> (String, usize, bool) {
    let expr: RecExpr<Bv> = expr_s.parse().unwrap();
    let analysis = WidthAnalysis {
        widths: widths.iter().map(|(n, w)| (Symbol::from(*n), *w)).collect(),
        datapath,
    };
    let runner = Runner::default()
        .with_egraph(EGraph::new(analysis))
        .with_expr(&expr)
        .run(&rules(guarded));
    let (cost, best) = Extractor::new(&runner.egraph, AreaCost).find_best(runner.roots[0]);
    let factored = best.to_string().starts_with("(*");
    (best.to_string(), cost, factored)
}

fn main() {
    println!("Distributivity applied only where the intermediate sum fits.\n");
    println!("{:<15} {:>9}  {:<22} {:>5}  {:<22} {:>5}",
             "operands", "datapath", "guarded: extracted", "cost", "unguarded: extracted", "cost");
    println!("{}", "-".repeat(92));

    let cases: &[(&str, &[(&str, u32)], u32, &str)] = &[
        ("(+ (* a b) (* a c))", &[("a", 8), ("b", 8), ("c", 8)], 16,
         "sum needs 9 of 16 bits -- sound"),
        ("(+ (* a b) (* a c))", &[("a", 8), ("b", 15), ("c", 15)], 16,
         "sum needs 16 of 16 bits -- sound"),
        ("(+ (* a b) (* a c))", &[("a", 8), ("b", 16), ("c", 16)], 16,
         "sum needs 17 of 16 bits -- BLOCKED"),
        ("(+ (* a b) (* a c))", &[("a", 4), ("b", 32), ("c", 32)], 32,
         "sum needs 33 of 32 bits -- BLOCKED"),
    ];

    let mut unsound = 0;
    for (e, w, dp, note) in cases {
        let (g_best, g_cost, g_fact) = optimise(e, w, *dp, true);
        let (u_best, u_cost, u_fact) = optimise(e, w, *dp, false);
        let ops: Vec<String> = w.iter().map(|(n, b)| format!("{n}:{b}")).collect();
        println!("{:<15} {:>9}  {:<22} {:>5}  {:<22} {:>5}   {}",
                 ops.join(","), dp, g_best, g_cost, u_best, u_cost, note);
        if !g_fact && u_fact { unsound += 1; }
    }
    println!();
    println!("Expression in every row: (+ (* a b) (* a c))");
    println!("The unguarded rule factored {unsound} case(s) the guarded rule refused.");

    println!("Those are exactly the circuits formal/dist_narrow.sby refutes: smaller,");
    println!("cheaper by the cost model, and wrong. The guard is not a conservatism");
    println!("knob -- it is the difference between an optimiser and a bug generator.");
}
