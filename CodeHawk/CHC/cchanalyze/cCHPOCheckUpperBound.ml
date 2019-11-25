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
open CCHTypesUtil
open CCHTypesToPretty

(* cchpre *)
open CCHMemoryBase
open CCHMemoryReference
open CCHPOPredicate
open CCHPreTypes
open CCHProofObligation
   
(* cchanalyze *)
open CCHAnalysisTypes

let x2p = xpr_formatter#pr_expr
let p2s = pretty_to_string
let x2s x = p2s (x2p x)

let cd = CCHDictionary.cdictionary
let stri = string_of_int

let straddr s =
  let index = cd#index_string s in
  "address of string literal(" ^ (stri index) ^ ") with length " ^ (stri (String.length s))

  (* An address is guaranteed to satisfy the upper-bound requirement if
   * - it is passed as a parameter (that is, it is the responsibility of the caller when
   *   passing a pointer, that it is either null, or points within the bounds of a memory
   *   region, as the receiving function has no way of checking this), or
   * - it has an external base address and a zero offset
   * - it is equal to a heap address that has been cast to the target type, or
   * - it is the return value from a function call (that is, it is the responsibility of
   *   the function returning the pointer, that it is either null, or points within the
   *   bounds of a memory region, as the receiving function has no way of checking this)
   * - it is equal to a frozen field value, as primary proof obligations for upper bound
   *    are generated for each field assignment (i.e., true by inductive hypothesis)
   * 
   * The requirement for an upper bound is lifted to the api if the pointer is equal to the
   * initial value (+ offset)  of a struct value pointed to by a parameter
   * 
   * Note: the inductive hypothesis for the result of pointer arithmetic is in general
   * not strong enough to support the upper bound; however, all pointer arithmetic within
   * a dereferencing operation has been strengthened, such that the result is actually
   * dereferencable.
   *)


class upper_bound_checker_t
        (poq:po_query_int)
        (typ:typ)
        (e:exp)
        (invs:invariant_int list) =
object (self)

  method private memref_to_string memref =
    "memory base: " ^ (p2s (memory_base_to_pretty memref#get_base))

  (* ----------------------------- safe ------------------------------------- *)

  method private memref_implies_safe invindex memref =
    let deps = DLocal [ invindex ] in
    let _ = poq#set_diagnostic_arg
          1 ("memory address: " ^ (self#memref_to_string memref)) in
    match memref#get_base with
    | CGlobalAddress gvar ->
       let (gvinfo,offset) = poq#env#get_global_variable gvar in
       let msg = "address of global variable: " ^ gvinfo.vname in
       Some (deps,msg)
    | CStringLiteral _ ->
       let msg = "address of string literal" in
       Some (deps,msg)
    | CStackAddress svar ->
       let (vinfo,offset) = poq#env#get_local_variable svar in
       let msg = "address of stack variable: " ^ vinfo.vname in
       Some (deps,msg)
    | CBaseVar svar ->
       let msg = "address of externally provided variable/field: "
                 ^ svar#getName#getBaseName in
       Some (deps,msg)
    | _ ->
       None


  method private var_implies_safe invindex v =
    let deps = DLocal [ invindex ] in
    if poq#env#is_initial_parameter_value v then
      let par = poq#env#get_initial_value_variable v in
      let msg = "initial value of parameter: " ^ par#getName#getBaseName
                ^ " satisfies upper bound by IH" in
      Some (deps,msg)
    else if poq#env#is_initial_global_value v then
      let var = poq#env#get_initial_value_variable v in
      let msg = "initial value of global value: " ^ var#getName#getBaseName
                ^ " satisfies upper bound by IH" in
      Some (deps,msg)     (* TBD: check intervening calls *)
    else if poq#env#is_function_return_value v then
      let callee = poq#env#get_callvar_callee v in
      let msg = "return value from function " ^ callee.vname
                ^ " satisfies upper bound by IH" in
      Some (deps,msg)
    else if poq#env#is_memory_address v then
      let (memref,offset) = poq#env#get_memory_address v in
      match offset with
      | NoOffset -> self#memref_implies_safe invindex memref
      | Field ((fname,_),NoOffset) ->
         begin
           match self#memref_implies_safe invindex memref with
           | Some (deps,msg) ->
              let msg = "field offset: " ^ fname ^ "; "  ^ msg in
              Some (deps,msg)
           | _ ->
              None
         end
      | _ -> None
    else
      None

  method private xpr_implies_safe invindex x =
    match x with
    | XVar v -> self#var_implies_safe invindex v
    | XConst (IntConst n) when n#equal numerical_zero ->
       let deps = DLocal [ invindex ] in
       let msg = "value is null pointer" in
       Some (deps,msg)
    | XOp (XMinus, [ xp1 ; XConst (IntConst n)]) when n#geq numerical_zero ->
       begin
         match self#xpr_implies_safe invindex xp1 with
         | Some (deps,msg) ->
            let msg = msg ^ " with negative offset of: " ^ n#toString in
            Some (deps,msg)
         | _ -> None
       end
    | _ -> None

  method private xprlist_implies_safe invindex l =
    match l with
    | [] -> None
    | h::tl ->
       match self#xpr_implies_safe invindex h with
       | Some r ->
          List.fold_left (fun acc x ->
              match acc with
              | None -> None
              | Some (deps,msg) ->
                 match self#xpr_implies_safe invindex x with
                 | Some (d,m) ->
                    let deps = join_dependencies deps d in
                    let msg = msg ^ "; " ^ m in
                    Some (deps,msg)
                 | _ -> None) (Some r) tl
       | _ -> None

  method private inv_implies_safe inv =
    match inv#upper_bound_xpr with
    | Some x -> self#xpr_implies_safe inv#index x
    | _ ->
       match inv#upper_bound_xpr_alternatives with
       | Some [] | None -> None
       | Some l -> self#xprlist_implies_safe inv#index l

  method check_safe =
    match invs with
    | [] -> false
    | _ ->
       match poq#get_buffer_offset_size 2 typ e with
       | Some (vname,xsize,xoffset,deps) ->
          let xconstraint = XOp (XLt, [ xoffset ; xsize ]) in
          let sconstraint = simplify_xpr xconstraint in
          if is_true sconstraint then
            let msg = "offset: " ^ (x2s xoffset) ^ " is less than the size of buffer: "
                      ^ vname ^ ": " ^ (x2s xsize) in
            begin
              poq#record_safe_result deps msg ;
              true
            end
          else
            begin
              poq#set_diagnostic_arg
                2 ("remaining constraint: " ^ (x2s sconstraint)) ;
              false
            end
       | _ ->       
          List.fold_left (fun acc inv ->
              acc ||
                match self#inv_implies_safe inv with
                | Some (deps,msg) ->
                   begin
                     poq#record_safe_result deps msg  ;
                     true
                   end
                | _ -> false) false invs
      
  (* ----------------------- violation -------------------------------------- *)
  method check_violation = false
  (* ----------------------- delegation ------------------------------------- *)

  method private inv_implies_delegation inv =
    match inv#expr with
    | Some x when poq#is_api_expression x ->
       let pred = PUpperBound (typ,poq#get_api_expression x) in
       let deps = DEnvC ([ inv#index ],[ ApiAssumption pred ]) in
       let msg = "condition " ^ (p2s (po_predicate_to_pretty pred))
                 ^ " delegated to the api" in
       Some (deps,msg)
    | _ -> None
       
  method check_delegation =
    match invs with
    | [] -> false
    | _ ->
       List.fold_left (fun acc inv ->
           acc ||
             match self#inv_implies_delegation inv with
             | Some (deps,msg) ->
                begin
                  poq#record_safe_result deps msg ;
                  true
                end
             | _ -> false) false invs
      
end


let check_upper_bound (poq:po_query_int) (typ:typ) (e:exp) =
  let invs = poq#get_invariants 2 in
  let _ = poq#set_diagnostic_invariants 2 in
  let checker = new upper_bound_checker_t poq typ e invs in
  checker#check_safe || checker#check_violation || checker#check_delegation
