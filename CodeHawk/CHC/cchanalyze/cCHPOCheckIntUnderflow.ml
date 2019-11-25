(* =============================================================================
   CodeHawk C Analyzer 
   Author: Henny Sipma
   ------------------------------------------------------------------------------
   The MIT License (MIT)
 
   Copyright (c) 2005-2019 Kestrel Technology LLC

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:
 
   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.
  
   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE.
   ============================================================================= *)

(* chlib *)
open CHNumerical
open CHPretty
   
(* chutil *)
open CHPrettyUtil
   
(* xprlib *)
open Xprt
open XprTypes
open XprToPretty
open Xsimplify
   
(* cchlib *)
open CCHBasicTypes
open CCHLibTypes
open CCHSumTypeSerializer
open CCHTypesToPretty
open CCHTypesUtil

(* cchpre *)
open CCHInvariantFact
open CCHPreTypes
open CCHPOPredicate
open CCHProofObligation
   
(* cchanalyze *)
open CCHAnalysisTypes
open CCHPOCheckIntUtil

let x2p = xpr_formatter#pr_expr
let p2s = pretty_to_string
let x2s x = p2s (x2p x)
let e2s e = p2s (exp_to_pretty e)

let nonneg (x:xpr_t) =
  match x with
  | XConst (IntConst n) -> n#geq numerical_zero
  | _ -> false    

let nonpos (x:xpr_t) =
  match x with
  | XConst (IntConst n) -> n#leq numerical_zero
  | _ -> false

(* ========================================================================== *)
(* ===================================== PlusA ============================== *)
(* ========================================================================== *)
class plus_checker
        (poq:po_query_int)
        (e1:exp)
        (e2:exp)
        (invs1:invariant_int list)
        (invs2:invariant_int list)
        (k:ikind) =
object (self)

  val safelb = get_safe_lowerbound k
  val xsafelb = num_constant_expr (get_safe_lowerbound k)

  method private global_str x =
    match x with
    | XVar v when poq#env#is_initial_global_value v -> " (global)"
    | _ -> ""

  method private var_implies_non_negative e invindex v =
    if poq#env#is_function_return_value v then
      let callee = poq#env#get_callvar_callee v in
      let (pcs,epcs) = poq#get_postconditions v in
      match epcs with
      | [] ->
         List.fold_left (fun acc (pc,_) ->
             match acc with
             | Some _ -> acc
             | _ ->
                match pc with
                | XRelationalExpr (Ge, ReturnValue, NumConstant n) when n#geq numerical_zero ->
                   let deps = DEnvC ([ invindex ],[ PostAssumption (callee.vid,pc) ]) in
                   let msg = "return value from "  ^ callee.vname ^ " is non-negative" in
                   Some (deps,msg)
                | _  -> None) None pcs
      | _ -> None
    else
      None

  method private inv_implies_non_negative e inv =
    match inv#lower_bound_xpr with
    | Some (XConst (IntConst n)) when n#geq numerical_zero ->
       let deps = DLocal [ inv#index ] in
       let msg = "value of " ^ (e2s e) ^ " is non-negative: " ^ n#toString in
       Some (deps,msg)
    | Some (XVar v) -> self#var_implies_non_negative e inv#index v
    | _ -> None

  method private mk_safe_constraint (x1:xpr_t) (x2:xpr_t) =
    let xresult = XOp (XPlus, [ x1 ; x2 ]) in
    XOp (XGe, [ xresult ; xsafelb ])

  method private mk_violation_constraint (x1:xpr_t) (x2:xpr_t) =
    let xresult = XOp (XPlus, [ x1 ; x2 ]) in
    XOp (XLt, [ xresult ; xsafelb ])

  method private get_predicate e1 e2 = PIntUnderflow (PlusA, e1, e2, k)

  (* ----------------------------- safe ------------------------------------- *)

  method private inv_implies_safe inv1 inv2 =
    match (inv1#lower_bound_xpr, inv2#lower_bound_xpr) with
    | (Some x1, Some x2) ->
       let safeconstraint = self#mk_safe_constraint x1 x2 in
       let simconstraint = simplify_xpr safeconstraint in
       let _ = poq#set_diagnostic_arg 2 ("LB: " ^ (x2s x1) ^ (self#global_str x1)) in
       let _ = poq#set_diagnostic_arg 3 ("LB: " ^ (x2s x2) ^ (self#global_str x2)) in
       if is_true simconstraint then
         let deps = DLocal [ inv1#index ; inv2#index ]  in
         let msg = "result of addition satisfies constraint " ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         let xresult = XOp (XPlus, [ x1 ; x2 ]) in
         begin
           match simplify_xpr xresult with
           | XVar v when poq#env#is_fixed_value v ->
              let deps = DLocal [ inv1#index ; inv2#index ] in
              let msg = "result of addition is equal to external value: "
                        ^ (x2s xresult) ^ " = " ^ v#getName#getBaseName in
              Some (deps,msg)
           | _ ->
              if poq#is_global_expression x1 then
                match x2 with
                | XConst (IntConst n) ->
                   let gx = poq#get_global_expression x1 in
                   let pred = self#get_predicate gx (make_constant_exp n) in
                   begin
                     match poq#check_implied_by_assumptions pred with
                     | Some pred ->
                        let deps = DEnvC ([inv1#index ; inv2#index ],
                                          [GlobalApiAssumption pred]) in
                        let msg = "safety constraint " ^ (x2s safeconstraint)
                                  ^ " implied by  global assumption: "
                                  ^ (p2s (po_predicate_to_pretty pred)) in
                        Some (deps,msg)
                     | _ ->
                        let xpred = po_predicate_to_xpredicate poq#fenv pred in
                        begin
                          poq#mk_global_request xpred ;
                          None
                        end
                   end
                | _ -> None
              else
                begin
                  poq#set_diagnostic
                    ("remaining constraint: " ^  (x2s simconstraint)) ;
                  None
                end
         end
    | (Some x1,_) ->
       let _ = poq#set_diagnostic_arg 2 ("LB: " ^ (x2s x1) ^ (self#global_str x1)) in
       self#inv_implies_non_negative e1 inv1
    | (_, Some x2) ->
       let _ = poq#set_diagnostic_arg 3 ("LB: " ^ (x2s x2) ^ (self#global_str x2)) in
       self#inv_implies_non_negative e2 inv2
    | _ -> None

  method check_safe =
    match invs1 with
    | [] ->
       begin
         match invs2 with
         | [] -> false
         | _ ->
            List.fold_left (fun acc inv ->
                acc ||
                  match self#inv_implies_non_negative e2 inv with
                  | Some (deps,msg) ->
                     begin
                       poq#record_safe_result deps msg ;
                       true
                     end
                  | _ -> false) false invs2
       end
    | _ ->
       match invs2 with
       | [] ->
          List.fold_left (fun acc inv ->
              acc ||
                match self#inv_implies_non_negative e1 inv with
                | Some (deps,msg) ->
                   begin
                     poq#record_safe_result deps msg ;
                     true
                   end
                | _ -> false) false invs1
       | _ ->
          List.fold_left (fun acc1 inv1 ->
              acc1 ||
                List.fold_left (fun acc2 inv2 ->
                    acc2 ||
                      match self#inv_implies_safe inv1 inv2 with
                      | Some (deps,msg) ->
                         begin
                           poq#record_safe_result deps msg ;
                           true
                         end
                      | _ -> false) acc1 invs2) false invs1
         
  (* ----------------------- violation ------------------------------------- *)

  method private universal_violation inv1 inv2 =
    match (inv1#upper_bound_xpr, inv2#upper_bound_xpr) with
    | (Some x1, Some x2) ->
       let safeconstraint = self#mk_safe_constraint x1 x2 in
       let violationconstraint = self#mk_violation_constraint x1 x2 in
       let simconstraint = simplify_xpr violationconstraint  in
       if is_true simconstraint then
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "UB on result of addition violates condition "
                   ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         None
    | _ -> None

  method private existential_violation inv1 inv2 =
    match (get_existential_min_values poq inv1, get_existential_min_values poq inv2) with
    | ([],_) | (_,[]) -> None
    | (vl1,vl2) ->
       List.fold_left (fun acc1 (b1,deps1,msg1) ->
           match acc1 with
           | Some _ -> acc1
           | _ ->
              List.fold_left (fun acc2 (b2,deps2,msg2) ->
                  match acc2 with
                  | Some _ -> acc2
                  | _ ->
                     if (b1#add b2)#lt safelb then
                       let deps = join_dependencies deps1 deps2 in
                       let msg = "result of addition: "
                                 ^ (b1#add b2)#toString
                                 ^ " violates safe LB: " ^ safelb#toString
                                 ^ " (" ^ msg1 ^ ";  " ^ msg2 ^ ")" in
                       Some (deps,msg)
                     else
                       None) acc1 vl2) None vl1
      
  method check_violation =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 acc2 ||
                   match self#universal_violation inv1 inv2 with
                   | Some (deps,msg) ->
                      begin
                        poq#record_violation_result deps msg ;
                        true
                      end
                   | _ ->
                      match self#existential_violation inv1 inv2 with
                      | Some (deps,msg) ->
                         begin
                           poq#record_violation_result deps msg ;
                           true
                         end
                      | _ -> false) acc1 invs2) false invs1

  (* ----------------------- delegation ------------------------------------- *)

  method private inv_implies_delegation inv1 inv2 =
    match (inv1#expr, inv2#expr) with
    | (Some x1, Some x2) ->
       begin
         match (poq#x2api x1, poq#x2api x2) with
         | (Some a1, Some a2) ->
            let pred = self#get_predicate a1 a2 in
            let deps = DEnvC ([ inv1#index ; inv2#index ],[ApiAssumption pred]) in
            let msg = "condition " ^  (p2s (po_predicate_to_pretty pred))
                      ^ " delegated to api" in
            Some (deps,msg)
         | _ -> None
       end
    | _ -> None
         
  method check_delegation =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    |  _ ->
        List.fold_left (fun acc1 inv1 ->
            acc1 ||
              List.fold_left (fun acc2 inv2 ->
                  acc2 ||
                    match self#inv_implies_delegation inv1 inv2 with
                    | Some (deps,msg) ->
                       begin
                         poq#record_safe_result deps msg ;
                         true
                       end
                    | _ -> false) acc1 invs2) false invs1
end

(* ========================================================================== *)
(* ===================================== Mult =============================== *)
(* ========================================================================== *)

class mult_checker
        (poq:po_query_int)
        (e1:exp)
        (e2:exp)
        (invs1:invariant_int list)
        (invs2:invariant_int list)
        (k:ikind) =
object (self)

  val safelb = get_safe_lowerbound k
  val xsafelb = num_constant_expr (get_safe_lowerbound k)

  method private global_str x =
    match x with
    | XVar v when poq#env#is_initial_global_value v -> " (global)"
    | _ -> ""

  method private inv_implies_non_positive e inv =
    match inv#upper_bound_xpr with
    | Some (XConst (IntConst n)) when n#leq numerical_zero ->
       let deps = DLocal [ inv#index ] in
       let msg = "value of " ^ (e2s e) ^ " is non-positive: " ^ n#toString in
       Some (deps,msg)
    | _ -> None

  method private inv_implies_non_negative e inv =
    match inv#lower_bound_xpr with
    | Some (XConst (IntConst n)) when n#geq numerical_zero ->
       let deps = DLocal [ inv#index ] in
       let msg = "value of " ^ (e2s e) ^ " is non-negative: " ^ n#toString in
       Some (deps,msg)
    | _ -> None

  method private is_positive inv =
    match inv#lower_bound_xpr with
    | Some (XConst (IntConst n)) -> n#gt numerical_zero
    | _ -> false

  method private is_negative inv =
    match inv#upper_bound_xpr with
    | Some (XConst (IntConst n)) -> n#lt numerical_zero
    | _ -> false                 

  method private mk_safe_constraint (x1:xpr_t) (x2:xpr_t) =
    let xresult = XOp (XMult, [ x1 ; x2 ]) in
    XOp (XGe, [ xresult ; xsafelb ])

  method private mk_violation_constraint (x1:xpr_t) (x2:xpr_t) =
    let xresult = XOp (XMult, [ x1 ; x2 ]) in
    XOp (XLt, [ xresult ; xsafelb ])

  method private get_predicate e1 e2 = PIntUnderflow (Mult, e1, e2, k)

  (* ----------------------------- safe ------------------------------------- *)

  method private inv_implies_safe_np inv1 inv2 =
    match (inv1#lower_bound_xpr, inv2#upper_bound_xpr) with
    | (Some x1, Some x2) ->
       let safeconstraint = self#mk_safe_constraint x1 x2 in
       let simconstraint  = simplify_xpr safeconstraint in
       let _ = poq#set_diagnostic_arg 2 ("LB: " ^ (x2s x1) ^ (self#global_str x1)) in
       let _ = poq#set_diagnostic_arg 3 ("UB: " ^ (x2s x2) ^ (self#global_str x2)) in
       if is_true simconstraint then
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "result of lower-upper bound multiplication satisfies constraint "
                   ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         if poq#is_global_expression x1 then
           match x2 with
           | XConst (IntConst n) ->
              let gx = poq#get_global_expression x1 in
              let pred = self#get_predicate gx (make_constant_exp n) in
              begin
                match poq#check_implied_by_assumptions pred with
                | Some pred ->
                   let deps = DEnvC ([ inv1#index ; inv2#index ],[GlobalApiAssumption pred]) in
                   let msg = "safety constraint " ^ (x2s safeconstraint)
                             ^ " implied by global assumption: "
                             ^ (p2s (po_predicate_to_pretty pred)) in
                   Some (deps,msg)
                | _ ->
                   let xpred =  po_predicate_to_xpredicate poq#fenv pred in
                   begin
                     poq#mk_global_request xpred ;
                     None
                   end
              end
           | _ -> None
         else
           None
    | (Some x1, _) ->
       let _ = poq#set_diagnostic_arg 2 ("LB: " ^ (x2s x1) ^ (self#global_str x1)) in
       self#inv_implies_non_negative e1 inv1
    | (_, Some x2) ->
       let _ = poq#set_diagnostic_arg 3 ("UB: " ^ (x2s x2) ^ (self#global_str x2)) in
       self#inv_implies_non_positive e2 inv2
    | _ -> None                    

  method private inv_implies_safe_pn inv1 inv2 =
    match (inv1#upper_bound_xpr, inv2#lower_bound_xpr) with
    | (Some x1, Some x2) ->
       let safeconstraint = self#mk_safe_constraint x1 x2 in
       let simconstraint = simplify_xpr safeconstraint in
       let _ = poq#set_diagnostic_arg 2 ("UB: " ^ (x2s x1) ^ (self#global_str x1)) in
       let _ = poq#set_diagnostic_arg 3 ("LB: " ^ (x2s x2) ^ (self#global_str x2)) in
       if is_true simconstraint then
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "result of upper-lower bound multiplication satisfies constraint "
                   ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         if poq#is_global_expression x1 then
           match x2 with
           | XConst (IntConst n) ->
              let gx = poq#get_global_expression x1 in
              let pred = self#get_predicate gx (make_constant_exp n) in
              begin
                match poq#check_implied_by_assumptions pred with
                | Some pred ->
                   let deps = DEnvC ([ inv1#index ; inv2#index ],[GlobalApiAssumption pred]) in
                   let msg = "safety constraint " ^ (x2s safeconstraint)
                             ^ " implied by global assumption: "
                             ^ (p2s (po_predicate_to_pretty pred)) in
                   Some (deps,msg)
                | _ ->
                   let xpred = po_predicate_to_xpredicate poq#fenv pred in
                   begin
                     poq#mk_global_request xpred ;
                     None
                   end
              end
           | _ -> None
         else
           None
    | (Some x1, _) ->
       let _ = poq#set_diagnostic_arg 2 ("UB: " ^ (x2s x1) ^ (self#global_str x1)) in
       self#inv_implies_non_positive e1 inv1
    | (_, Some x2) ->
       let _ = poq#set_diagnostic_arg 3 ("LB: " ^ (x2s x2) ^ (self#global_str x2)) in
       self#inv_implies_non_negative e2 inv2
    | _ -> None
                                                             

  method private check_safe_np =
    match invs1 with
    | [] ->
       begin
         match invs2 with
         | [] -> None
         | _ ->
            List.fold_left (fun acc inv ->
                match acc with
                | Some _ -> acc
                | _ -> self#inv_implies_non_negative e2 inv) None invs2
       end
    | _ ->
       match invs2 with
       | [] ->
          List.fold_left (fun acc inv ->
              match acc with
              | Some _ -> acc
              | _ -> self#inv_implies_non_positive e1 inv) None invs1
       | _ ->
          List.fold_left (fun acc1 inv1 ->
              match acc1 with
              | Some _ -> acc1
              | _ ->
                 List.fold_left (fun acc2 inv2 ->
                     match acc2 with
                     | Some _ -> acc2
                     | _ -> self#inv_implies_safe_np inv1 inv2) acc1 invs2) None invs1
                                   

  method private check_safe_pn =
    match invs1 with
    | [] ->
       begin
         match invs2 with
         | [] -> None
         | _ ->
            List.fold_left (fun acc inv ->
                match acc with
                | Some _ -> acc
                | _ -> self#inv_implies_non_positive e2 inv) None invs2
       end
    | _ ->
       match invs2 with
       | [] ->
          List.fold_left (fun acc inv ->
              match acc with
              | Some _ -> acc
              | _ -> self#inv_implies_non_negative e1 inv) None invs1
       | _ ->
          List.fold_left (fun acc1 inv1 ->
              match acc1 with
              | Some _ -> acc1
              | _ ->
                 List.fold_left (fun acc2 inv2 ->
                     match acc2 with
                     | Some _ -> acc2
                     | _ -> self#inv_implies_safe_pn inv1 inv2) acc1 invs2) None invs1
         
  method check_safe = (* safe if ub * lb >= MIN and lb * ub >= MIN *)
    match (self#check_safe_pn, self#check_safe_np) with
    | (Some (deps1,msg1), Some (deps2,msg2)) ->
       let deps = join_dependencies deps1 deps2 in
       let msg = "UB*LB: " ^ msg1 ^ "; LB*UB: " ^ msg2 in
       begin
         poq#record_safe_result deps msg ;
         true
       end
    | (Some (deps1,msg1), _) ->
       begin
         poq#set_diagnostic ("UB*LB: " ^ msg1) ;
         false
       end
    | (_, Some (deps2,msg2)) ->
       begin
         poq#set_diagnostic ("LB*UB: " ^ msg2) ;
         false
       end
    | _ -> false

  (* ----------------------- violation -------------------------------------- *)

  method private inv_implies_universal_violation_np inv1 inv2 =
    match (inv1#upper_bound_xpr,inv2#lower_bound_xpr) with
    | (Some x1, Some x2) when self#is_negative inv1 && self#is_positive inv2 ->
       let violationconstraint = self#mk_violation_constraint x1 x2 in
       let simconstraint = simplify_xpr violationconstraint in
       if is_true simconstraint then
         let safeconstraint = self#mk_safe_constraint x1 x2 in
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "neg_UB*pos_LB result of multiplication violates constraint "
                   ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         None
    | _  -> None
                                 
  method private universal_violation_np =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 match self#inv_implies_universal_violation_np inv1 inv2 with
                 | Some (deps,msg) ->
                    begin
                      poq#record_violation_result deps msg ;
                      true
                    end
                 | _ -> false) acc1 invs2) false invs1

  method private inv_implies_universal_violation_pn inv1 inv2 =
    match (inv1#lower_bound_xpr, inv2#upper_bound_xpr) with
    | (Some x1, Some x2)  when self#is_positive inv1 && self#is_negative inv2 ->
       let violationconstraint = self#mk_violation_constraint x1 x2 in
       let simconstraint =  simplify_xpr violationconstraint in
       if is_true simconstraint then
         let safeconstraint = self#mk_safe_constraint x1 x2 in
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "pos_LB*neg_UB result of multiplication violates constraint "
                    ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         None
    | _ -> None

  method private universal_violation_pn =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 match self#inv_implies_universal_violation_pn inv1 inv2 with
                 | Some (deps,msg) ->
                    begin
                      poq#record_violation_result deps msg ;
                      true
                    end
                 | _ -> false) acc1 invs2) false invs1

  method private inv_implies_existential_violation xsl1 xsl2 =
    match (xsl1,xsl2) with
    | ( [],_) | (_,[]) -> None
    | _ ->
       List.fold_left (fun acc1 (b1,deps1,msg1) ->
           match acc1 with
           | Some _ -> acc1
           | _ ->
              List.fold_left (fun acc2 (b2,deps2,msg2) ->
                  match acc2 with
                  | Some _ -> acc2
                  | _ ->
                     if (b1#mult b2)#lt safelb then
                       let deps = join_dependencies deps1 deps2 in
                       let msg = "result of multiplication: " ^  (b1#mult b2)#toString
                                 ^ " violates safe LB: " ^ safelb#toString
                                 ^ " (" ^ msg1 ^ "; " ^ msg2  ^ ")" in
                       Some (deps,msg)
                     else
                       None) acc1 xsl2) None xsl1

  method private existential_violation_pn =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 acc2 ||
                   (let xsl1 = get_existential_max_values poq inv1 in
                    let xsl2 = get_existential_min_values poq inv2 in
                    match self#inv_implies_existential_violation xsl1 xsl2 with
                    | Some (deps,msg) ->
                       begin
                         poq#record_violation_result deps msg ;
                         true
                       end
                    | _ -> false)) acc1 invs2) false invs1

  method private existential_violation_np =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 acc2 ||
                   (let xsl1 = get_existential_min_values poq inv1 in
                    let xsl2 = get_existential_max_values poq inv2 in
                    match self#inv_implies_existential_violation xsl1 xsl2 with
                    | Some (deps,msg) ->
                       begin
                         poq#record_violation_result deps msg ;
                         true
                       end
                    | _ -> false)) acc1 invs2) false invs1
      
  method check_violation =
    self#universal_violation_pn     (* lb1 * ub2 < MIN, lb1 > 0, ub2 < 0 *)
    || self#universal_violation_np  (* ub1 * lb2 < MIN, ub1 < 0, lb2 > 0 *)
    || self#existential_violation_pn
    || self#existential_violation_np

  (* ----------------------- delegation ------------------------------------- *)

  method private inv_implies_delegation inv1 inv2 =
    match (inv1#expr, inv2#expr) with
    | (Some x1, Some x2) ->
       begin
         match (poq#x2api x1, poq#x2api x2) with
         | (Some a1, Some a2)
              when poq#is_api_expression x1 || poq#is_api_expression x2 ->
            let pred = self#get_predicate a1 a2 in
            let deps = DEnvC ([inv1#index ; inv2#index ],[ApiAssumption pred]) in
            let msg = "condition " ^  (p2s (po_predicate_to_pretty pred))
                      ^ " delegated to api" in
            Some (deps,msg)
         | _ -> None
       end
    | _ -> None

  method check_delegation =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 acc2 ||
                   match self#inv_implies_delegation inv1 inv2 with
                   | Some (deps,msg) ->
                      begin
                        poq#record_safe_result deps msg ;
                        true
                      end
                   | _ -> false) acc1 invs2) false invs1

end

(* ========================================================================== *)
(* ===================================== MinusA ============================= *)
(* ========================================================================== *)

class minus_checker
        (poq:po_query_int)
        (e1:exp)
        (e2:exp)
        (invs1:invariant_int list)
        (invs2:invariant_int list)
        (k:ikind) =
object (self)

  val safelb = get_safe_lowerbound k
  val xsafelb = num_constant_expr (get_safe_lowerbound k)

  method private global_str x =
    match x with
    | XVar v when poq#env#is_initial_global_value v -> " (global)"
    | _ -> ""

  method private inv_implies_non_negative e inv =
    match inv#lower_bound_xpr with
    | Some (XConst (IntConst n)) when n#geq numerical_zero ->
       let deps = DLocal [ inv#index ] in
       let msg = "value of " ^ (e2s e) ^ " is non-negative: " ^ n#toString in
       Some (deps,msg)
    | _ -> None

  method private inv_implies_non_positive e inv =
    match inv#upper_bound_xpr with
    | Some (XConst (IntConst n)) when n#leq numerical_zero ->
       let deps = DLocal [ inv#index ] in
       let msg = "value of " ^ (e2s e) ^ " is non-positive: " ^ n#toString in
       Some (deps,msg)
    | _ -> None

  method private mk_safe_constraint (x1:xpr_t) (x2:xpr_t) =
    let xresult = XOp (XMinus, [ x1 ; x2 ]) in
    XOp (XGe, [ xresult ; xsafelb ])

  method private mk_violation_constraint (x1:xpr_t) (x2:xpr_t) =
    let xresult = XOp (XMinus, [ x1 ; x2 ]) in
    XOp (XLt, [ xresult ; xsafelb ])

  method private get_predicate e1 e2 = PIntUnderflow (MinusA, e1, e2, k)

  (* ----------------------------- safe ------------------------------------- *)

  method private inv_implies_safe inv1 inv2 =
    match (inv1#lower_bound_xpr, inv2#upper_bound_xpr) with
    | (Some x1, Some x2) ->
       let safeconstraint = self#mk_safe_constraint x1 x2 in
       let simconstraint = simplify_xpr safeconstraint in
       let _ = poq#set_diagnostic_arg 2 ("LB: " ^ (x2s x1) ^ (self#global_str x1)) in
       let _ = poq#set_diagnostic_arg 3 ("UB: " ^ (x2s x2) ^ (self#global_str x2)) in
       if is_true simconstraint then
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "result of subtraction satisfies constraint " ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         let xresult = XOp (XMinus, [ x1 ; x2 ]) in
         begin
           match simplify_xpr xresult with
           | XVar v when poq#env#is_fixed_value v ->
              let deps = DLocal [ inv1#index ; inv2#index ] in
              let msg = "result of subtraction is equal to external value: "
                        ^ (x2s xresult) ^ " = " ^  v#getName#getBaseName in
              Some (deps,msg)
           | _ ->
              if poq#is_global_expression x1 then
                match x2 with
                | XConst (IntConst n) ->
                   let gx = poq#get_global_expression x1 in
                   let pred = self#get_predicate gx (make_constant_exp n) in
                   begin
                     match poq#check_implied_by_assumptions pred with
                     | Some pred ->
                        let deps = DEnvC ( [ inv1#index ; inv2#index ],
                                           [ GlobalApiAssumption pred ]) in
                        let msg = "safety constraint  " ^  (x2s safeconstraint)
                                  ^ " implied by global assumption: "
                                  ^ (p2s (po_predicate_to_pretty pred)) in
                        Some (deps,msg)
                     | _ ->
                        let xpred = po_predicate_to_xpredicate poq#fenv pred in
                        begin
                          poq#mk_global_request xpred ;
                          None
                        end
                   end
                | _ -> None
              else
                begin
                  poq#set_diagnostic
                    ("remaining constraint: " ^ (x2s simconstraint)) ;
                  None
                end
         end
    | (Some x1, _) ->
       let _ = poq#set_diagnostic_arg 2 ("LB: " ^ (x2s x1) ^ (self#global_str x1)) in
       self#inv_implies_non_negative e1 inv1
    | (_, Some x2) ->
       let _ = poq#set_diagnostic_arg 3 ("UB: " ^ (x2s x2) ^ (self#global_str x2)) in
       self#inv_implies_non_positive e2 inv2
    | _ -> None
                                                            
  method check_safe =
    match invs1 with
    | [] ->
       begin
         match invs2 with
         | [] -> false
         | _ ->
            List.fold_left (fun acc inv ->
                acc ||
                  match  self#inv_implies_non_positive e2 inv with
                  | Some (deps,msg) ->
                     begin
                       poq#record_safe_result deps msg ;
                       true
                     end
                  | _ -> false) false invs2
       end
    | _ ->
       match invs2 with
       | [] ->
          List.fold_left (fun acc inv ->
              acc ||
                match self#inv_implies_non_negative e1 inv with
                | Some (deps,msg) ->
                   begin
                     poq#record_safe_result deps msg ;
                     true
                   end
                | _ -> false) false invs1
       | _ ->
          List.fold_left (fun acc1 inv1 ->
              acc1 ||
                List.fold_left (fun acc2 inv2 ->
                    acc2 ||
                      match self#inv_implies_safe inv1 inv2 with
                      | Some (deps,msg) ->
                         begin
                           poq#record_safe_result deps msg ;
                           true
                         end
                      | _ -> false) acc1 invs2) false invs1

  (* ----------------------- violation ------------------------------------- *)

  method private universal_violation inv1 inv2 =
    match (inv1#upper_bound_xpr, inv2#lower_bound_xpr) with
    | (Some x1, Some x2) ->
       let safeconstraint = self#mk_safe_constraint x1 x2 in
       let violationconstraint = self#mk_violation_constraint x1 x2 in
       let simconstraint = simplify_xpr violationconstraint in
       if is_true simconstraint then
         let deps = DLocal [ inv1#index ; inv2#index ] in
         let msg = "UB on result of subtraction violates condition "
                   ^ (x2s safeconstraint) in
         Some (deps,msg)
       else
         None
    | _ -> None       

  method private existential_violation inv1 inv2 =
    match (get_existential_min_values poq inv1,get_existential_max_values poq inv2) with
    | ([],_) | (_,[]) -> None
    | (vl1,vl2) ->
       List.fold_left (fun acc1 (b1,deps1,msg1) ->
           match acc1 with
           | Some _ -> acc1
           | _ ->
              List.fold_left (fun acc2 (b2,deps2,msg2) ->
                  match acc2 with
                  | Some _ -> acc2
                  | _ ->
                     if (b1#sub b2)#lt safelb then
                       let deps = join_dependencies deps1 deps2 in
                       let msg = "result of subtraction: "
                                 ^ (b1#sub b2)#toString
                                 ^ " violates safe LB: " ^ safelb#toString
                                 ^ " (" ^ msg1 ^ "; " ^ msg2 ^ ")" in
                       Some (deps,msg)
                     else
                       None) acc1 vl2) None vl1
      
  method check_violation =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 acc2 ||
                   match self#universal_violation inv1 inv2 with
                   | Some (deps,msg) ->
                      begin
                        poq#record_violation_result deps msg ;
                        true
                      end
                   | _ ->
                      match self#existential_violation inv1 inv2 with
                      | Some (deps,msg) ->
                         begin
                           poq#record_violation_result deps msg ;
                           true
                         end
                      | _ -> false) acc1 invs2) false invs1

  (* ----------------------- delegation ------------------------------------- *)

  method private inv_implies_delegation inv1 inv2 =
    match (inv1#expr, inv2#expr) with
    | (Some x1, Some x2) ->
       begin
         match (poq#x2api x1, poq#x2api x2) with
         | (Some a1, Some a2)
              when poq#is_api_expression x1 || poq#is_api_expression x2 ->
            let pred = self#get_predicate a1 a2 in
            let deps = DEnvC ([ inv1#index ; inv2#index ],[ApiAssumption pred]) in
            let msg = "condition " ^ (p2s (po_predicate_to_pretty pred))
                      ^ " delegated to api" in
            Some (deps,msg)
         | _ -> None
       end
    | _ -> None
         
  method check_delegation =
    match (invs1,invs2) with
    | ([],_) | (_,[]) -> false
    | _ ->
       List.fold_left (fun acc1 inv1 ->
           acc1 ||
             List.fold_left (fun acc2 inv2 ->
                 acc2 ||
                   match self#inv_implies_delegation inv1 inv2 with
                   | Some (deps,msg) ->
                      begin
                        poq#record_safe_result deps msg ;
                        true
                      end
                   | _ -> false) acc1 invs2) false invs1

end


class div_checker
        (poq:po_query_int)
        (e1:exp)
        (e2:exp)
        (invs1:invariant_int list)
        (invs2:invariant_int list)
        (k:ikind) =
object
  method check_safe = false
  method check_violation = false
  method check_delegation = false
end

class generic_checker
        (poq:po_query_int)
        (e1:exp)
        (e2:exp)
        (invs1:invariant_int list)
        (invs2:invariant_int list)
        (k:ikind) =
object
  method check_safe = false
  method check_violation = false
  method check_delegation = false
end


let check_int_underflow
      (poq:po_query_int)
      (op:binop)
      (e1:exp)
      (e2:exp)
      (k:ikind) =
  let values2 = poq#get_invariants 2 in
  let values3 = poq#get_invariants 3 in
  let _ = poq#set_diagnostic_invariants 2 in
  let _ = poq#set_diagnostic_invariants 3 in
  let checker =
    match op with
    | PlusA -> new plus_checker poq e1 e2 values2 values3 k
    | Mult -> new mult_checker poq e1 e2 values2 values3 k
    | MinusA -> new minus_checker poq e1 e2 values2 values3 k
    | Div -> new div_checker poq e1 e2 values2 values3 k
    | _ -> new generic_checker poq e1 e2 values2 values3 k in
  checker#check_safe || checker#check_violation || checker#check_delegation
