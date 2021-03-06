(* =============================================================================
   CodeHawk Binary Analyzer 
   Author: Henny Sipma
   ------------------------------------------------------------------------------
   The MIT License (MIT)
 
   Copyright (c) 2021 Aarno Labs LLC

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
open CHPretty
open CHCommon
open CHNumerical
open CHLanguage
open CHUtils

(* chutil *)
open CHLogger

(* xprlib *)
open Xprt
open XprTypes
open XprToPretty
open XprUtil
open Xsimplify

(* bchlib *)
open BCHBasicTypes
open BCHCallTarget
open BCHCodegraph
open BCHCPURegisters
open BCHDoubleword
open BCHFloc
open BCHFunctionData
open BCHFunctionInfo
open BCHFunctionSummary
open BCHLibTypes
open BCHLocation
open BCHLocationInvariant
open BCHMemoryReference
open BCHSpecializations
open BCHSystemInfo
open BCHSystemSettings
open BCHUtilities
open BCHVariable
open BCHVariableType

(* bchlibarm32 *)
open BCHARMAssemblyBlock
open BCHARMAssemblyFunction
open BCHARMAssemblyFunctions
open BCHARMAssemblyInstruction
open BCHARMAssemblyInstructions
open BCHARMCHIFSystem
open BCHARMCodePC
open BCHARMConditionalExpr
open BCHARMOpcodeRecords
open BCHARMOperand
open BCHARMTypes
open BCHDisassembleARM

module B = Big_int_Z
module LF = CHOnlineCodeSet.LanguageFactory

let valueset_domain = "valuesets"
let x2p = xpr_formatter#pr_expr

let make_code_label ?src ?modifier (address:ctxt_iaddress_t) =
  let name =
    if address = "exit" || address = "?" then
      "exit"
    else
      "pc_" ^ address in
  let atts = match modifier with
    | Some s -> [s]
    | _ -> [] in
  let atts =
    if address = "?" then
      "unresolved-jump" :: atts
    else
      atts in
  let atts = match src with
    | Some s -> s#to_fixed_length_hex_string :: atts | _ -> atts in
  ctxt_string_to_symbol name ~atts address

let get_invariant_label (loc:location_int) =
  ctxt_string_to_symbol "invariant" loc#ci

let package_transaction
      (finfo:function_info_int) (label:symbol_t) (cmds:cmd_t list) =
  let cmds =
    List.filter
      (fun cmd -> match cmd with SKIP -> false | _ -> true) cmds in
  let cnstAssigns = finfo#env#end_transaction in
  TRANSACTION (label, LF.mkCode (cnstAssigns @ cmds), None)

let make_conditional_predicate
      ~(condinstr: arm_assembly_instruction_int)
      ~(testinstr: arm_assembly_instruction_int)
      ~(condloc: location_int)
      ~(testloc: location_int) =
  let (frozenvars, optxpr) =
    arm_conditional_expr
      ~condopc:condinstr#get_opcode
      ~testopc:testinstr#get_opcode
      ~condloc:condloc
      ~testloc:testloc in
  (frozenvars, optxpr)


let make_instr_local_tests
    ~(condinstr:arm_assembly_instruction_int)
    ~(testinstr:arm_assembly_instruction_int)
    ~(condloc:location_int)
    ~(testloc:location_int) =
  let testfloc = get_floc testloc in
  let condfloc = get_floc condloc in
  let env = testfloc#f#env in
  let reqN () = env#mk_num_temp in
  let reqC i = env#request_num_constant i in
  let (frozenVars, optboolxpr) =
    arm_conditional_expr
      ~condopc:condinstr#get_opcode
      ~testopc:testinstr#get_opcode
      ~condloc
      ~testloc in
  let convert_to_chif expr =
    let (cmds,bxpr) = xpr_to_boolexpr reqN reqC expr in
    cmds @ [ASSERT bxpr] in
  let convert_to_assert expr  =
    let vars = variables_in_expr expr in
    let varssize = List.length vars in
    let xprs =
      if varssize = 1 then
	let var = List.hd vars in
	let extxprs = condfloc#inv#get_external_exprs var in
	let extxprs =
          List.map (fun e -> substitute_expr (fun v -> e) expr) extxprs in
	expr :: extxprs
      else if varssize = 2 then
	let varlist = vars in
	let var1 = List.nth varlist 0 in
	let var2 = List.nth varlist 1 in
	let extxprs1 = condfloc#inv#get_external_exprs var1 in
	let extxprs2 = condfloc#inv#get_external_exprs var2 in
	let xprs = List.concat
	  (List.map
	     (fun e1 ->
	       List.map
		 (fun e2 ->
		   substitute_expr
                     (fun w -> if w#equal var1 then e1 else e2) expr)
		 extxprs2)
	     extxprs1) in
	expr :: xprs
      else
	[expr] in
    List.concat (List.map convert_to_chif xprs) in
  let make_asserts exprs =
    List.concat (List.map convert_to_assert exprs) in
  let make_branch_assert exprs =
    let commands = List.map convert_to_assert exprs in
    [BRANCH (List.map LF.mkCode commands)] in
  let make_assert expr =
    convert_to_assert expr in
  let make_test_code expr =
    if is_conjunction expr then
      let conjuncts = get_conjuncts expr in
      make_asserts conjuncts
    else if is_disjunction expr then
      let disjuncts = get_disjuncts expr in
      make_branch_assert disjuncts
    else
      make_assert expr in
  match optboolxpr with
    Some bxpr ->
      let thencode = make_test_code bxpr in
      let elsecode = make_test_code (simplify_xpr (XOp (XLNot, [bxpr]))) in
      (frozenVars, Some (thencode, elsecode))
  | _ -> (frozenVars, None)
  
let make_tests
    ~(condinstr:arm_assembly_instruction_int)
    ~(testinstr:arm_assembly_instruction_int)
    ~(condloc:location_int)
    ~(testloc:location_int) =
  let testfloc = get_floc testloc in
  let condfloc = get_floc condloc in
  let env = testfloc#f#env in
  let reqN () = env#mk_num_temp in
  let reqC i = env#request_num_constant i in
  let (frozenVars, optboolxpr) =
    arm_conditional_expr
      ~condopc:condinstr#get_opcode
      ~testopc:testinstr#get_opcode
      ~condloc
      ~testloc in
  let convert_to_chif expr =
    let (cmds,bxpr) = xpr_to_boolexpr reqN reqC expr in
    cmds @ [ASSERT bxpr] in
  let convert_to_assert expr  =
    let vars = variables_in_expr expr in
    let varssize = List.length vars in
    let xprs =
      if varssize = 1 then
	let var = List.hd vars in
	let extxprs = condfloc#inv#get_external_exprs var in
	let extxprs =
          List.map (fun e -> substitute_expr (fun v -> e) expr) extxprs in
	expr :: extxprs
      else if varssize = 2 then
	let varlist = vars in
	let var1 = List.nth varlist 0 in
	let var2 = List.nth varlist 1 in
	let extxprs1 = condfloc#inv#get_external_exprs var1 in
	let extxprs2 = condfloc#inv#get_external_exprs var2 in
	let xprs = List.concat
	  (List.map
	     (fun e1 ->
	       List.map
		 (fun e2 ->
		   substitute_expr
                     (fun w -> if w#equal var1 then e1 else e2) expr)
		 extxprs2)
	     extxprs1) in
	expr :: xprs
      else
	[expr] in
    List.concat (List.map convert_to_chif xprs) in
  let make_asserts exprs =
    let _ = env#start_transaction in
    let commands = List.concat (List.map convert_to_assert exprs) in
    let const_assigns = env#end_transaction in
    const_assigns @ commands in
  let make_branch_assert exprs =
    let _ = env#start_transaction in
    let commands = List.map convert_to_assert exprs in
    let branch = BRANCH (List.map LF.mkCode commands) in
    let const_assigns = env#end_transaction in
    const_assigns @ [branch] in
  let make_assert expr =
    let _ = env#start_transaction in
    let commands = convert_to_assert expr in
    let const_assigns = env#end_transaction in
    const_assigns @ commands in
  let make_test_code expr =
    if is_conjunction expr then
      let conjuncts = get_conjuncts expr in
      make_asserts conjuncts
    else if is_disjunction expr then
      let disjuncts = get_disjuncts expr in
      make_branch_assert disjuncts
    else
      make_assert expr in
  match optboolxpr with
    Some bxpr ->
      let thencode = make_test_code bxpr in
      let elsecode = make_test_code (simplify_xpr (XOp (XLNot, [bxpr]))) in
      (frozenVars, Some (thencode, elsecode))
  | _ -> (frozenVars, None)

let make_local_tests
      (condinstr: arm_assembly_instruction_int) (condloc: location_int) =
  let floc = get_floc condloc in
  let env = floc#f#env in
  let reqN () = env#mk_num_temp in
  let reqC i = env#request_num_constant i in
  let boolxpr =
    match condinstr#get_opcode with
    | CompareBranchZero (op, _) ->
       let x = op#to_expr floc in
       XOp (XEq, [x; zero_constant_expr])
    | CompareBranchNonzero (op, _) ->
       let x = op#to_expr floc in
       XOp (XNe, [x; zero_constant_expr])
    | _ ->
       raise (BCH_failure
                (LBLOCK [STR "Unexpected condition: "; condinstr#toPretty])) in
  let convert_to_chif expr =
    let (cmds,bxpr) = xpr_to_boolexpr reqN reqC expr in
    cmds @ [ASSERT bxpr] in
  let make_assert x =
    let _ = env#start_transaction in
    let commands = convert_to_chif x in
    let const_assigns = env#end_transaction in
    const_assigns @ commands in
  let thencode = make_assert boolxpr in
  let elsecode = make_assert (simplify_xpr (XOp (XLNot, [boolxpr]))) in
  (thencode, elsecode)


let make_local_condition
      (condinstr: arm_assembly_instruction_int)
      (condloc: location_int)
      (blocklabel: symbol_t)
      (thenaddr: ctxt_iaddress_t)
      (elseaddr: ctxt_iaddress_t) =
  let thenlabel = make_code_label thenaddr in
  let elselabel = make_code_label elseaddr in
  let (thentest, elsetest) = make_local_tests condinstr condloc in
  let make_node_and_label testcode tgtaddr modifier =
    let src = condloc#i in
    let nextlabel = make_code_label ~src ~modifier tgtaddr in
    let transaction = TRANSACTION (nextlabel, LF.mkCode testcode, None) in
    (nextlabel, [transaction]) in
  let (thentestlabel, thennode) =
    make_node_and_label thentest thenaddr "then" in
  let (elsetestlabel, elsenode) =
    make_node_and_label elsetest elseaddr "else" in
  let thenedges =
    [(blocklabel, thentestlabel); (thentestlabel, thenlabel)] in
  let elseedges =
    [(blocklabel, elsetestlabel); (elsetestlabel, elselabel) ] in
  ([(thentestlabel, thennode); (elsetestlabel, elsenode)], thenedges @ elseedges)


let make_condition
    ~(condinstr:arm_assembly_instruction_int)
    ~(testinstr:arm_assembly_instruction_int)
    ~(condloc:location_int)
    ~(testloc:location_int)
    ~(blocklabel:symbol_t)
    ~(thenaddr:ctxt_iaddress_t)
    ~(elseaddr:ctxt_iaddress_t) =
  let thenlabel = make_code_label thenaddr in
  let elselabel = make_code_label elseaddr in
  let (frozenVars, tests) =
    make_tests ~condloc ~testloc ~condinstr ~testinstr in
  match tests with
    Some (thentest, elsetest) ->
      let make_node_and_label testcode tgtaddr modifier =
	let src = condloc#i in
	let nextlabel = make_code_label ~src ~modifier tgtaddr in
	let testcode = testcode @ [ABSTRACT_VARS frozenVars] in
	let transaction = TRANSACTION (nextlabel, LF.mkCode testcode, None) in
	(nextlabel, [transaction]) in
      let (thentestlabel, thennode) =
	make_node_and_label thentest thenaddr "then" in
      let (elsetestlabel, elsenode) =
	make_node_and_label elsetest elseaddr "else" in
      let thenedges =
	[(blocklabel, thentestlabel); (thentestlabel, thenlabel)] in
      let elseedges =
	[(blocklabel, elsetestlabel); (elsetestlabel, elselabel) ] in
      ([(thentestlabel, thennode); (elsetestlabel, elsenode)], thenedges @ elseedges)
  | _ ->
    let abstractlabel =
      make_code_label ~modifier:"abstract" testloc#ci in
    let transaction =
      TRANSACTION (abstractlabel, LF.mkCode [ABSTRACT_VARS frozenVars], None) in
    let edges = [(blocklabel, abstractlabel);
                 (abstractlabel, thenlabel);
		 (abstractlabel, elselabel)] in
    ([(abstractlabel, [transaction])], edges)
    

let translate_arm_instruction
      ~(funloc:location_int)
      ~(codepc:arm_code_pc_int)
      ~(blocklabel:symbol_t)
      ~(exitlabel:symbol_t)
      ~(cmds:cmd_t list) =
  let (ctxtiaddr, instr) = codepc#get_next_instruction in
  let faddr = funloc#f in
  let finfo = get_function_info faddr in
  let loc = ctxt_string_to_location faddr ctxtiaddr in  (* instr location *)
  let invlabel = get_invariant_label loc in
  let invop = OPERATION { op_name = invlabel ; op_args = [] } in
  let frozenAsserts =
    List.map (fun (v,fv) -> ASSERT (EQ (v,fv)))
      (finfo#get_test_variables ctxtiaddr) in
  let rewrite_expr floc x:xpr_t =
    let xpr = floc#inv#rewrite_expr x floc#env#get_variable_comparator in
    let rec expand x =
      match x with
      | XVar v when floc#env#is_symbolic_value v ->
         expand (floc#env#get_symbolic_value_expr v)
      | XOp (op,l) -> XOp (op, List.map expand l)
      | _ -> x in
    simplify_xpr (expand xpr) in
  let default newcmds =
    let floc = get_floc loc in
    let pcv = (pc_r RD)#to_variable floc in
    let iaddr12 = (loc#i#add_int 12)#to_numerical in
    let pcassign = floc#get_assign_commands pcv (XConst (IntConst iaddr12)) in
    ([], [], cmds @ frozenAsserts @ (invop :: (newcmds @ pcassign))) in
  let make_conditional_commands (c: arm_opcode_cc_t) (cmds: cmd_t list) =
    if finfo#has_associated_cc_setter ctxtiaddr then
      let testiaddr = finfo#get_associated_cc_setter ctxtiaddr in
      let testloc = ctxt_string_to_location faddr testiaddr in
      let testaddr = (ctxt_string_to_location faddr testiaddr)#i in
      let testinstr = (!arm_assembly_instructions#at_address testaddr) in
      let (frozenvars, tests) =
        make_instr_local_tests ~condloc:loc ~testloc ~condinstr:instr ~testinstr in
      match tests with
      | Some (thentest, elsetest) ->
         default [BRANCH [LF.mkCode (thentest @ cmds); LF.mkCode elsetest]]
      | _ ->
         default [BRANCH [LF.mkCode cmds; LF.mkCode [SKIP]]]
    else
      default [BRANCH [LF.mkCode cmds; LF.mkCode [SKIP]]] in

  match instr#get_opcode with

  | Branch (c, op, _)
    | BranchExchange (c, op) when is_cond_conditional c ->
     let thenaddr =
       if op#is_absolute_address then
         (make_i_location loc op#get_absolute_address)#ci
       else if op#is_register && op#get_register = ARLR then
         "exit"
       else
         "?" in
     let elseaddr = codepc#get_false_branch_successor in
     let cmds = cmds @ [invop] in
     let transaction = package_transaction finfo blocklabel cmds in
     if finfo#has_associated_cc_setter ctxtiaddr then
       let testiaddr = finfo#get_associated_cc_setter ctxtiaddr in
       let testloc = ctxt_string_to_location faddr testiaddr in
       let testaddr = (ctxt_string_to_location faddr testiaddr)#i in
       let (nodes, edges) =
         make_condition
           ~condinstr:instr
           ~testinstr:(!arm_assembly_instructions#at_address testaddr)
           ~condloc:loc
           ~testloc
           ~blocklabel
           ~thenaddr
           ~elseaddr in
       ((blocklabel, [transaction]) :: nodes, edges, [])
     else
       let thenlabel = make_code_label thenaddr in
       let elselabel = make_code_label elseaddr in
       let nodes = [(blocklabel, [transaction])] in
       let edges = [(blocklabel, thenlabel); (blocklabel, elselabel)] in
       (nodes, edges, [])

  | CompareBranchZero (op, tgt)
    | CompareBranchNonzero (op, tgt) ->
     let thenaddr = (make_i_location loc tgt#get_absolute_address)#ci in
     let elseaddr = codepc#get_false_branch_successor in
     let cmds = cmds @ [invop] in
     let transaction = package_transaction finfo blocklabel cmds in
     let (nodes, edges) =
       make_local_condition instr loc blocklabel thenaddr elseaddr in
     ((blocklabel, [transaction]) :: nodes, edges, [])

  | Branch (_, op, _)
    | BranchExchange (ACCAlways, op) when op#is_absolute_address ->
     default []

  | Branch (_, op, _)
    | BranchExchange (ACCAlways, op) when op#is_register && op#get_register = ARLR ->
     default []

  (* -------------------------------------------------------------- Add -- *
   * if ConditionPassed() then
   *   shifted = Shift(R[m], shift_t, shift_n, APSR.C)
   *   (result, carry, overflow) = AddWithCarry(R[n], shifted, '0')
   *   if d == 15 then
   *     ALUWritePC(result);
   *   else
   *     R[d] = result;
   *     if setflags then
   *       APSR.N = result<31>;
   *       APSR.Z = IsZeroBit(result);
   *       APSR.C = carry;
   *       APSR.V = overflow;
   *------------------------------------------------------------------------- *)
  | Add (_, c, rd, rn, rm, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrn = rn#to_expr floc in
     let xrm = rm#to_expr floc in
     let cmds = floc#get_assign_commands vrd (XOp (XPlus, [xrn; xrm])) in
     (match c with
      | ACCAlways -> default cmds
      | _ -> make_conditional_commands c cmds)

  | Adr (ACCAlways, dst, src) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let rhs = src#to_expr floc in
     let cmds = floc#get_assign_commands lhs rhs in
     default (lhscmds @ cmds)

  | ArithmeticShiftRight(setflags, ACCAlways, rd, rn, rm, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrn = rn#to_expr floc in
     let xrm = rm#to_expr floc in
     let asrr =
       match xrm with
       | XConst (IntConst n) when n#toInt = 2->
          XOp (XDiv, [xrn; XConst (IntConst (mkNumerical 4))])
       | _ -> XOp (XShiftrt, [xrn; xrm]) in
     let cmds = floc#get_assign_commands vrd asrr in
     default cmds

  | ArithmeticShiftRight (_, _, rd, _, _, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  | BitFieldClear (_, rd, _, _, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  | BitwiseAnd (setflags, ACCAlways, rd, rn, rm, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrn = rn#to_expr floc in
     let xrm = rm#to_expr floc in
     let result = XOp (XBAnd, [xrn; xrm]) in
     let cmds = floc#get_assign_commands vrd result in
     default cmds

  | BitwiseAnd (_, _, rd, _, _, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  (* ---------------------------------------------------------- BitwiseNot -- *
   * if immediate
   *   result = NOT(imm32);
   * if register
   *   (shifted, carry) = Shift_C(R[m], shift_t, shift_n, APSR.C);
   *   result = NOT(shifted);
   * if d == 15 then
   *   ALUWritePC(result);
   * else
   *   R[d] = result;
   *   if setflags then
   *     APSR.N = result<31>;
   *     APSR.Z = IsZeroBit(result);
   *     APSR.C = carry;
   * ------------------------------------------------------------------------ *)
  | BitwiseNot (setflags, ACCAlways, dst, src) when src#is_immediate ->
     let floc = get_floc loc in
     let rhs = src#to_expr floc in
     let notrhs =
       match rhs with
       | XConst (IntConst n) when n#equal numerical_zero ->
          XConst (IntConst numerical_one#neg)
       | XConst (IntConst n) -> XConst (IntConst ((nume32#sub n)#sub numerical_one))
       | _ -> XConst XRandom in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmd = floc#get_assign_commands lhs notrhs in
     default (cmd @ lhscmds)

  | BitwiseNot (_, _, dst, src) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | BitwiseOr (_, _, rd, _, _, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  (* ---------------------------------------------------------- BranchLink -- *
   * if CurrentInstrSet() == InstrSet_ARM then
   *   LR = PC - 4;
   * else
   *   LR = PC<31:1> : '1';
   * if targetInstrSet == InstrSet_ARM then
   *   targetAddress = Align(PC,4) + imm32;
   * else
   *   targetAddress = PC + imm32;
   * SelectInstrSet(targetInstrSet);
   * BranchWritePC(targetAddress);
   * ------------------------------------------------------------------------ *)
  | BranchLink (ACCAlways, tgt) when tgt#is_absolute_address ->
     default (get_floc loc)#get_arm_call_commands

  | BranchLinkExchange (ACCAlways, tgt) when tgt#is_absolute_address ->
     default (get_floc loc)#get_arm_call_commands

  | ByteReverseWord (_, dst, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | Compare (_, src1, _, _) ->
     let floc = get_floc loc in
     let _ =
       floc#inv#rewrite_expr (src1#to_expr floc)
         floc#env#get_variable_comparator in
     default []

  | CompareNegative _ ->
     default []

  | CountLeadingZeros (_, rd, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = rd#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | IfThen (c, xyz) when instr#is_aggregate ->
     let floc = get_floc loc in
     let testiaddr = finfo#get_associated_cc_setter ctxtiaddr in
     let testloc = ctxt_string_to_location faddr testiaddr in
     let testaddr = testloc#i in
     let testinstr = !arm_assembly_instructions#at_address testaddr in
     let dstop = instr#get_aggregate_dst in
     let (frozenvars, optpredicate) =
       make_conditional_predicate
         ~condinstr:instr
         ~testinstr:testinstr
         ~condloc:loc
         ~testloc:testloc in
     let cmds =
       match optpredicate with
       | Some p ->
          let (lhs, lhscmds) = dstop#to_lhs floc in
          let cmds = floc#get_assign_commands lhs p in
          let _ =
            chlog#add
              "assign ite predicate"
              (LBLOCK [testaddr#toPretty;
                       STR ": " ;
                       lhs#toPretty;
                       STR " := ";
                       x2p p]) in
          let _ =
            chlog#add
              "ite assign cmds"
              (LBLOCK (List.map (command_to_pretty 0) cmds)) in
          lhscmds @ cmds
       | _ ->
          let _ =
            chlog#add
              "no ite predicate"
              (LBLOCK [testaddr#toPretty; STR ": " ; testinstr#toPretty]) in
          [] in
     default cmds
     
  (* -------------------------------------------------------- LoadRegister -- *
   * offset = Shift(R[m], shift_t, shift_n, APSR.C);
   * offset_addr = if add then (R[n] + offset) else (R[n] - offset);
   * address = if index then offset_addr else R[n];
   * data = MemU[address,4];
   * if wback then R[n] = offset_addr;
   * if t == 15 then
   *   if address<1:0> == '00' then
   *     LoadWritePC(data)
   *   else
   *     UNPREDICTABLE
   * elsif UnalignedSupport() || address<1:0> == '00' then
   *   R[t] = data;
   * else
   *   R[t] = ROR(data, 8*UInt(address<1:0>));
   * ------------------------------------------------------------------------ *)
  | LoadRegister (c, dst, base, src, _) ->
     let floc = get_floc loc in
     let rhs =
       floc#inv#rewrite_expr (src#to_expr floc)
         floc#env#get_variable_comparator in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let updatecmds =
       if src#is_offset_address_writeback then
         let addr = src#to_updated_offset_address floc in
         let (baselhs, baselhscmds) = base#to_lhs floc in
         let ucmds = floc#get_assign_commands baselhs addr in
         baselhscmds @ ucmds
       else
         [] in
     let cmds = lhscmds @ (floc#get_assign_commands lhs rhs) @ updatecmds in
     (match c with
      | ACCAlways -> default cmds
      | _ -> make_conditional_commands c cmds)

  | LoadRegisterByte (ACCAlways, dst, base, src, _) ->
     let floc = get_floc loc in
     let rhs = src#to_expr floc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmd = floc#get_assign_commands lhs rhs in
     default (cmd @ lhscmds)

  | LoadRegisterByte (_, dst, _, _, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | LoadRegisterDual (_, rt, rt2, _, _, mem, mem2) ->
     let floc = get_floc loc in
     let (lhs1, lhscmds1) = rt#to_lhs floc in
     let (lhs2, lhscmds2) = rt2#to_lhs floc in
     let rhs1 = mem#to_expr floc in
     let rhs2 = mem2#to_expr floc in
     let cmds1 = floc#get_assign_commands lhs1 rhs1 in
     let cmds2 = floc#get_assign_commands lhs2 rhs2 in
     default (lhscmds1 @ lhscmds2 @ cmds1 @ cmds2)

  | LoadRegisterExclusive (ACCAlways, dst, base, src) ->
     let floc = get_floc loc in
     let rhs =
       floc#inv#rewrite_expr (src#to_expr floc)
         floc#env#get_variable_comparator in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmd = floc#get_assign_commands lhs rhs in
     default (cmd @ lhscmds)

  | LoadRegisterHalfword (ACCAlways, dst, base, _, src, _) ->
     let floc = get_floc loc in
     let rhs = src#to_expr floc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmd = floc#get_assign_commands lhs rhs in
     default (cmd @ lhscmds)

  | LoadRegisterHalfword (_, dst, _, _, _, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | LoadRegisterSignedHalfword (ACCAlways, rt, rn, rm, mem, _) ->
     let floc = get_floc loc in
     let rhs = mem#to_expr floc in
     let rhs = floc#inv#rewrite_expr rhs floc#env#get_variable_comparator in
     let (lhs, lhscmds) = rt#to_lhs floc in
     let is_external v = floc#env#is_function_initial_value v in
     let rec is_symbolic_expr x =
       match x with
       | XOp (_, l) -> List.for_all is_symbolic_expr l
       | XVar v -> is_external v
       | XConst _ -> true
       | XAttr _ -> false in
     (match rhs with
      | XConst  (IntConst n) when n#toInt > e15 ->
         let rhs = XOp (XPlus, [rhs; int_constant_expr (e32-e16)]) in
         let cmds = floc#get_assign_commands lhs rhs in
         default (lhscmds @ cmds)
      | _ ->
         if is_symbolic_expr rhs then
           let rhs = floc#env#mk_signed_symbolic_value rhs 16 32 in
           let cmds = floc#get_assign_commands lhs (XVar rhs) in
           default (lhscmds @ cmds)
         else
           let cmds = floc#get_abstract_commands lhs () in
           default (lhscmds @ cmds))

  | LoadRegisterSignedHalfword (_, rt, _, _, _, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = rt#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | LogicalShiftLeft (_, ACCAlways, rd, rn, rm, _) when rm#is_immediate ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrn = rn#to_expr floc in
     let p = rm#to_numerical#toInt in
     let m = mkNumerical_big (B.power_int_positive_int 2 p) in
     let cmds = floc#get_assign_commands vrd (XOp (XMult, [num_constant_expr m; xrn])) in
     default cmds

  | LogicalShiftLeft (_, ACCAlways, rd, rn, rm, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrn = rn#to_expr floc in
     let xrm = rm#to_expr floc in
     let result = XOp (XShiftlt, [xrn; xrm]) in
     let cmds = floc#get_assign_commands vrd result in
     default cmds

  | LogicalShiftLeft (_, _, rd, _, _, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  | LogicalShiftRight (_, ACCAlways, rd, rn, rm, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrn = rn#to_expr floc in
     let xrm = rm#to_expr floc in
     let result = XOp (XShiftrt, [xrn; xrm]) in
     let cmds = floc#get_assign_commands vrd result in
     default cmds

  | LogicalShiftRight (_, _, rd, _, _, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  (* ---------------------------------------------------------------- Move -- *
   * result = R[m];
   * if d == 15 then
   *   ALUWritePC(result);
   * else
   *   R[d] = result;
   *  if setflags then
   *    APSR.N = result<31>;
   *    APSR.Z = IsZeroBit(result);
   * ------------------------------------------------------------------------ *)
  | Move _ when instr#is_subsumed ->
     let _ =
       chlog#add
         "instr subsumed"
         (LBLOCK [(get_floc loc)#l#toPretty; STR ": "; instr#toPretty]) in
     default []

  | Move (setflags, c, dst, src, _) ->
     let floc = get_floc loc in
     let rhs = src#to_expr floc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmd = floc#get_assign_commands lhs rhs in
     (match c with
      | ACCAlways ->  default (cmd @ lhscmds)
      | _ -> make_conditional_commands c (cmd @ lhscmds))

  | MoveRegisterCoprocessor (_, _, _, dst, _, _, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | MoveTop (ACCAlways, dst, src) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let rhs = dst#to_expr floc in
     let imm16 = src#to_expr floc in
     let ximm16 = XOp (XMult, [imm16; int_constant_expr e16]) in
     let xrdm16 = XOp (XMod, [rhs; int_constant_expr e16]) in
     let rhsxpr = XOp (XPlus, [xrdm16; ximm16]) in
     let cmds = floc#get_assign_commands lhs rhsxpr in
     default (cmds @ lhscmds)

  | MoveWide (c, dst, src) ->
     let floc = get_floc loc in
     let rhs = src#to_expr floc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_assign_commands lhs rhs in
     (match c with
      | ACCAlways -> default (cmds @ lhscmds)
      | _ -> make_conditional_commands c (cmds @ lhscmds))

  | MultiplySubtract (_, rd, _, _, ra) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = rd#to_lhs floc in
     let (lhsa, lhsacmds) = ra#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     let cmdsa = floc#get_abstract_commands lhsa () in
     default (lhscmds @ lhsacmds @ cmds @ cmdsa)

  (* ----------------------------------------------------------------- Pop -- *
   * address = SP;
   * for i = 0 to 14
   *   if registers<i> == '1' then
   *     R[i] = if UnalignedAllowed then
   *              MemU[address,4]
   *            else
   *              MemA[address,4];
   *     address = address + 4;
   * if registers<15> == '1' then
   *   if UnalignedAllowed then
   *     if address<1:0> == '00' then
   *       LoadWritePC(MemU[address,4]);
   *     else
   *       UNPREDICTABLE;
   *   else
   *     LoadWritePC(MemA[address,4]);
   * if registers<13> == '0' then SP = SP + 4*BitCount(registers);
   * if registers<13> == '1' then SP = bits(32) UNKNOWN;
   * ------------------------------------------------------------------------ *)

  | Pop (c, sp, rl, _) ->
     let floc = get_floc loc in
     let regcount = rl#get_register_count in
     let sprhs = sp#to_expr floc in
     let reglhss = rl#to_multiple_variable floc in
     let (stackops,_) =
       List.fold_left
         (fun (acc,off) reglhs ->
           let (splhs,splhscmds) = (sp_r RD)#to_lhs floc in
           let stackop = arm_sp_deref ~with_offset:off RD in
           let stackrhs = stackop#to_expr floc in
           let cmds1 = floc#get_assign_commands reglhs stackrhs in
           (acc @ cmds1 @ splhscmds, off+4)) ([],0) reglhss in
     let (splhs,splhscmds) = (sp_r WR)#to_lhs floc in
     let increm = XConst (IntConst (mkNumerical (4 * regcount))) in
     let cmds = floc#get_assign_commands splhs (XOp (XPlus, [sprhs; increm])) in
     (match c with
      | ACCAlways -> default (stackops @ cmds)
      | _ -> make_conditional_commands c (stackops @ cmds))

  (* ---------------------------------------------------------------- Push -- *
   * address = SP - 4*BitCount(registers);
   * for i = 0 to 14
   *   if registers<i> == '1' then
   *     if i == 13 && i != LowestSetBit(registers) then
   *       MemA[address,r] = bits(32) UNKNOWN;
   *     else
   *        if UnalignedAllowed then
   *          MemU[address,4] = R[i];
   *        else
   *          MemA[address,4] = R[i];
   *     address = address + 4;
   * if registers<15> == '1' then
   *   if UnalignedAllowed then
   *     MemU[address,4] = PCStoreValue();
   *   else
   *     MemA[address,4] = PCStoreValue();
   * SP = SP - 4*BitCount(registers);
   * ------------------------------------------------------------------------ *)
  | Push (ACCAlways, sp, rl, _) ->
     let floc = get_floc loc in
     let regcount = rl#get_register_count in
     let sprhs = sp#to_expr floc in     
     let rhsexprs = rl#to_multiple_expr floc in
     let rhsexprs = List.map (rewrite_expr floc) rhsexprs in
     let (stackops,_) =
       List.fold_left
         (fun (acc,off) rhsexpr ->
           let (splhs,splhscmds) = (sp_r RD)#to_lhs floc in
           let stackop = arm_sp_deref ~with_offset:off WR in
           let (stacklhs, stacklhscmds) = stackop#to_lhs floc in
           let cmds1 = floc#get_assign_commands stacklhs rhsexpr in
           (acc @ cmds1 @ stacklhscmds @ splhscmds, off+4)) ([],(-(4*regcount))) rhsexprs in
     let (splhs,splhscmds) = (sp_r WR)#to_lhs floc in
     let decrem = XConst (IntConst (mkNumerical(4 * regcount))) in
     let cmds = floc#get_assign_commands splhs (XOp (XMinus, [sprhs; decrem])) in
     default (stackops @ cmds)

  | Push (_, sp, rl, _) ->
     let floc = get_floc loc in
     let regcount = rl#get_register_count in
     let rhsexprs = rl#to_multiple_expr floc in
     let rhsexprs = List.map (rewrite_expr floc) rhsexprs in
     let (stackops,_) =
       List.fold_left
         (fun (acc,off) rhsexpr ->
           let (splhs,splhscmds) = (sp_r RD)#to_lhs floc in
           let stackop = arm_sp_deref ~with_offset:off WR in
           let (stacklhs, stacklhscmds) = stackop#to_lhs floc in
           let cmds1 = floc#get_abstract_commands stacklhs () in
           (acc @ cmds1 @ stacklhscmds @ splhscmds, off+4)) ([],(-(4*regcount))) rhsexprs in
     let (splhs,splhscmds) = (sp_r WR)#to_lhs floc in
     let cmds = floc#get_abstract_commands splhs () in
     default (stackops @ cmds)

  | ReverseSubtract(_, _, dst, _, _, _) ->
     let floc = get_floc loc in
     let vdst = dst#to_variable floc in
     let cmds = floc#get_abstract_commands vdst () in
     default cmds

  | ReverseSubtractCarry(_, _, dst, _, _) ->
     let floc = get_floc loc in
     let vdst = dst#to_variable floc in
     let cmds = floc#get_abstract_commands vdst () in
     default cmds

  | SignedDivide (ACCAlways, rd, rn, rm) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = rd#to_lhs floc in
     let dividend = rn#to_expr floc in
     let divisor = rm#to_expr floc in
     let rhs = XOp (XDiv, [dividend; divisor]) in
     let cmds = floc#get_assign_commands lhs rhs in
     default (lhscmds @ cmds)

  | SignedExtendHalfword (_, rd, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = rd#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | SignedMostSignificantWordMultiply (_, dst, _, _, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     default (lhscmds @ cmds)

  | SignedMostSignificantWordMultiplyAccumulate (_, dst, _, _, acc, _) ->
     let floc = get_floc loc in
     let (lhs, lhscmds) = dst#to_lhs floc in
     let (lhsacc, lhsacccmds) = acc#to_lhs floc in
     let cmds = floc#get_abstract_commands lhs () in
     let cmdsacc = floc#get_abstract_commands lhsacc () in
     default (lhscmds @ cmds @ lhsacccmds @ cmdsacc)

  | SignedMultiplyLong (_, _, rdlo, rdhi, _, _) ->
     let floc = get_floc loc in
     let vlo = rdlo#to_variable floc in
     let vhi = rdhi#to_variable floc in
     let cmdslo = floc#get_abstract_commands vlo () in
     let cmdshi = floc#get_abstract_commands vhi () in
     default (cmdslo @ cmdshi)

  | StoreRegister (c, rt, rn, mem, _) ->
     let floc = get_floc loc in
     let (vmem, memcmds) = mem#to_lhs floc in
     let xrt = rt#to_expr floc in
     let cmds = memcmds @ (floc#get_assign_commands vmem xrt) in
     (match c with
      | ACCAlways -> default cmds
      | _ -> make_conditional_commands c cmds)

  | StoreRegisterByte (c, rt, rn, mem, _) ->
     let floc = get_floc loc in
     let (vmem,memcmds) = mem#to_lhs floc in
     let xrt = rt#to_expr floc in
     let cmds = memcmds @ (floc#get_assign_commands vmem xrt) in
     let _ =
       chlog#add
         "STRB"
         (LBLOCK [loc#toPretty; STR ": "; vmem#toPretty; STR " to "; x2p xrt]) in
     (match c with
      | ACCAlways -> default cmds
      | _ -> make_conditional_commands c cmds)

  | StoreRegisterDual (ACCAlways, rt, rt2, _, _, mem, mem2) ->
     let floc = get_floc loc in
     let (vmem, memcmds) = mem#to_lhs floc in
     let (vmem2, mem2cmds) = mem2#to_lhs floc in
     let xrt = rt#to_expr floc in
     let xrt2 = rt2#to_expr floc in
     let cmds1 = floc#get_assign_commands vmem xrt in
     let cmds2 = floc#get_assign_commands vmem2 xrt2 in
     default (memcmds @ mem2cmds @ cmds1 @ cmds2)

  | StoreRegisterDual (_, _, _, _, _, mem, mem2) ->
     let floc = get_floc loc in
     let (vmem, memcmds) = mem#to_lhs floc in
     let (vmem2, mem2cmds) = mem2#to_lhs floc in
     let cmds1 = floc#get_abstract_commands vmem () in
     let cmds2 = floc#get_abstract_commands vmem2 () in
     default (memcmds @ mem2cmds @ cmds1 @ cmds2)

  | StoreRegisterExclusive (ACCAlways, rd, rt, rn, mem) ->
     let floc = get_floc loc in
     let (vmem,memcmds) = mem#to_lhs floc in
     let (vrd, vrdcmds) = rd#to_lhs floc in
     let xrt = rt#to_expr floc in
     let cmds = floc#get_assign_commands vmem xrt in
     let scmds = floc#get_abstract_commands vrd () in
     default (memcmds @ vrdcmds @ cmds @ scmds)

  | StoreRegisterExclusive (_, rd, _, _, mem) ->
     let floc = get_floc loc in
     let (vmem,memcmds) = mem#to_lhs floc in
     let (vrd, vrdcmds) = rd#to_lhs floc in
     let cmds = floc#get_abstract_commands vmem () in
     let scmds = floc#get_abstract_commands vrd () in
     default (memcmds @ vrdcmds @ cmds @ scmds)

  | StoreRegisterHalfword (ACCAlways, rt, rn, _, mem, _) ->
     let floc = get_floc loc in
     let (vmem,memcmds) = mem#to_lhs floc in
     let xrt = rt#to_expr floc in
     let cmds = floc#get_assign_commands vmem xrt in
     default (memcmds @ cmds)

  | StoreRegisterHalfword (_, _, _, _, mem, _) ->
     let floc = get_floc loc in
     let (vmem, memcmds) = mem#to_lhs floc in
     let cmds = floc#get_abstract_commands vmem () in
     default (memcmds @ cmds)

  (* ------------------------------------------------------------ Subtract -- *
   * if ConditionPassed() then
   *   (result, carry, overflow) = AddWithCarry (R[n], NOT9imm32), '1');
   *   R[d] = result;
   *   if setflags then
   *     APSR.N = result<31>;
   *     APSR.Z = IsZeroBit(result);
   *     APSR.C = carry;
   *     APSR.V = overflow
   * ------------------------------------------------------------------------- *)
  | Subtract (_, ACCAlways, dst, src1, src2, _) ->
     let floc = get_floc loc in
     let vdst = dst#to_variable floc in
     let xsrc1 = src1#to_expr floc in
     let xsrc2 = src2#to_expr floc in
     let cmds = floc#get_assign_commands vdst (XOp (XMinus, [xsrc1; xsrc2])) in
     default cmds

  | Subtract(_, _, dst, _, _, _) ->
     let floc = get_floc loc in
     let vdst = dst#to_variable floc in
     let cmds = floc#get_abstract_commands vdst () in
     default cmds

  | SubtractCarry(_, _, dst, _, _) ->
     let floc = get_floc loc in
     let vdst = dst#to_variable floc in
     let cmds = floc#get_abstract_commands vdst () in
     default cmds

  | UnsignedExtendByte (ACCAlways, rd, rm) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrm = rm#to_expr floc in
     (* let result = XOp (XMod, [xrm; XConst (IntConst (mkNumerical 256))]) in *)
     let result = xrm in
     let cmds = floc#get_assign_commands vrd result in
     default cmds

  | UnsignedExtendByte (_, rd, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  | UnsignedExtendHalfword (ACCAlways, rd, rm) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let xrm = rm#to_expr floc in
     (* let result = XOp (XMod, [xrm; XConst (IntConst (mkNumerical (256 * 256)))]) in *)
     let result = xrm in
     let cmds = floc#get_assign_commands vrd result in
     default cmds

  | UnsignedExtendHalfword (_, rd, _) ->
     let floc = get_floc loc in
     let vrd = rd#to_variable floc in
     let cmds = floc#get_abstract_commands vrd () in
     default cmds

  | UnsignedMultiplyLong (_, _, rdlo, rdhi, _, _) ->
     let floc = get_floc loc in
     let vlo = rdlo#to_variable floc in
     let vhi = rdhi#to_variable floc in
     let cmdslo = floc#get_abstract_commands vlo () in
     let cmdshi = floc#get_abstract_commands vhi () in
     default (cmdslo @ cmdshi)

  | instr ->
     let _ =
       chlog#add
         "no semantics"
         (LBLOCK [loc#toPretty;
                  STR ": ";
                  STR (arm_opcode_to_string instr)]) in
     default []
        

class arm_assembly_function_translator_t (f:arm_assembly_function_int) =
object (self)

  val finfo = get_function_info f#get_address
  val funloc =
    make_location {loc_faddr = f#get_address; loc_iaddr = f#get_address}
  val exitlabel =
    make_code_label
      ~modifier:"exit"
      (make_location {loc_faddr = f#get_address; loc_iaddr = f#get_address})#ci
  val codegraph = make_code_graph ()

  method translate_block (block:arm_assembly_block_int) =
    let codepc = make_arm_code_pc block in
    let blocklabel = make_code_label block#get_context_string in
    let rec aux cmds =
      let (nodes,edges,newcmds) =
        try
          translate_arm_instruction ~funloc ~codepc ~blocklabel ~exitlabel ~cmds
        with
        | BCH_failure p ->
           let msg =
             LBLOCK [STR "function: ";
                     funloc#toPretty;
                     STR ", block: ";
                     blocklabel#toPretty;
                     STR ": ";
                     p] in
           begin
             ch_error_log#add "translate arm block" msg;
             raise (BCH_failure msg)
           end in
      match nodes with
      | [] ->
         if codepc#has_more_instructions then
           aux newcmds
         (*
         else if codepc#has_conditional_successor then
           let (testloc,jumploc,theniaddr,elseiaddr,testexpr) =
             codepc#get_conditional_successor_info in
           let transaction = package_transaction finfo blocklabel newcmds in
           let (nodes,edges) =
             make_condition
               ~testloc ~jumploc ~theniaddr ~elseiaddr ~blocklabel ~testexpr in
           ((blocklabel, [transaction])::nodes, edges) *)
         else
           let transaction = package_transaction finfo blocklabel newcmds in
           let nodes = [(blocklabel, [transaction])] in
           let edges =
             List.map
               (fun succ ->
                 let succlabel = make_code_label succ in
                 (blocklabel, succlabel)) codepc#get_block_successors in
           (nodes, edges)
      | _ -> (nodes,edges) in
    let _ = finfo#env#start_transaction in
    let (nodes, edges) = aux [] in
    begin
      List.iter (fun (label, node) -> codegraph#add_node label node) nodes;
      List.iter (fun (src, tgt) -> codegraph#add_edge src tgt) edges
    end

  method private create_arg_deref_asserts
                   (finfo: function_info_int)
                   (reg: arm_reg_t)
                   (offset: int)
                   (optlb: int option)
                   (optub: int option) =
    let env = finfo#env in
    let reqN () = env#mk_num_temp in
    let reqC = env#request_num_constant in
    let ri = env#mk_initial_register_value (ARMRegister reg) in
    let _ = finfo#add_base_pointer ri in
    let rbase = env#mk_base_variable_reference ri in
    let memvar = env#mk_memory_variable rbase (mkNumerical offset) in
    let cmdasserts cxpr =
      let (cmds, bxpr) = xpr_to_boolexpr reqN reqC cxpr in
      cmds @ [ASSERT bxpr] in
    match (optlb, optub) with
    | (Some lb, Some ub) when lb = ub ->
       let cxpr = XOp (XEq, [XVar memvar; int_constant_expr lb]) in
       cmdasserts cxpr
    | (Some lb, Some ub) ->
       let c1xpr = XOp (XGe, [XVar memvar; int_constant_expr lb]) in
       let c2xpr = XOp (XLe, [XVar memvar; int_constant_expr ub]) in
       (cmdasserts c1xpr) @ (cmdasserts c2xpr)
    | (Some lb, _) ->
       let cxpr = XOp (XGe, [XVar memvar; int_constant_expr lb]) in
       cmdasserts cxpr
    | (_, Some ub) ->
       let cxpr = XOp (XLe, [XVar memvar; int_constant_expr ub]) in
       cmdasserts cxpr
    | _ -> []

  method private create_arg_scalar_asserts
                   (finfo: function_info_int)
                   (var: variable_t)
                   (optlb: int option)
                   (optub: int option) =
    let env = finfo#env in
    let reqN () = env#mk_num_temp in
    let reqC = env#request_num_constant in
    (* let regvar = env#mk_arm_register_variable reg in *)
    let cmdasserts cxpr =
      let (cmds, bxpr) = xpr_to_boolexpr reqN reqC cxpr in
      cmds @ [ASSERT bxpr] in
    match (optlb, optub) with
    | (Some lb, Some ub) when lb = ub ->
       let cxpr = XOp (XEq, [XVar var; int_constant_expr lb]) in
       cmdasserts cxpr
    | (Some lb, Some ub) ->
       let c1xpr = XOp (XGe, [XVar var; int_constant_expr lb]) in
       let c2xpr = XOp (XLe, [XVar var; int_constant_expr ub]) in
       (cmdasserts c1xpr) @ (cmdasserts c2xpr)
    | (Some lb, _) ->
       let cxpr = XOp (XGe, [XVar var; int_constant_expr lb]) in
       cmdasserts cxpr
    | (_, Some ub) ->
       let cxpr = XOp (XLe, [XVar var; int_constant_expr ub]) in
       cmdasserts cxpr
    | _ -> []


  method private create_arg_asserts
                   (finfo: function_info_int)
                   (c: (string * int option * int option * int option)) =
    let (name, optoffset, optlb, optub) = c in
    if (String.length name) > 1 && (String.sub name 0 2) = "0x" then
      let gv = finfo#env#mk_global_variable (string_to_doubleword name)#to_numerical in
      (* let gv_in = finfo#env#mk_initial_memory_value gv in *)
      self#create_arg_scalar_asserts finfo gv optlb optub
    else
      let reg = armreg_from_string name in
      match optoffset with
      | Some offset -> self#create_arg_deref_asserts finfo reg offset optlb optub
      | _ ->
         let regvar = finfo#env#mk_arm_register_variable reg in
         self#create_arg_scalar_asserts finfo regvar optlb optub

  method private create_args_asserts
                   (finfo: function_info_int)
                   (argconstraints:
                      (string * int option * int option * int option) list) =
    List.concat
      (List.map (fun c -> self#create_arg_asserts finfo c) argconstraints)

  method private get_entry_cmd
                   (argconstraints:
                      (string * int option * int option * int option) list) =
    let env = finfo#env in
    let _ = env#start_transaction in
    let freeze_initial_register_value (reg:arm_reg_t) =
      let regVar = env#mk_arm_register_variable reg in
      let initVar = env#mk_initial_register_value (ARMRegister reg) in
      ASSERT (EQ (regVar, initVar)) in
    let freeze_external_memory_values (v:variable_t) =
      let initVar = env#mk_initial_memory_value v in
      ASSERT (EQ (v, initVar)) in
    let rAsserts = List.map freeze_initial_register_value arm_regular_registers in
    let externalMemvars = env#get_external_memory_variables in
    let externalMemvars = List.filter env#has_constant_offset externalMemvars in
    let _ = chlog#add
              "external memory variables"
              (LBLOCK [finfo#get_address#toPretty; pretty_print_list externalMemvars (fun v -> v#toPretty) " [" ", " "]"]) in
    let mAsserts = List.map freeze_external_memory_values externalMemvars in
    let sp0 = env#mk_initial_register_value (ARMRegister ARSP) in
    let _ = finfo#add_base_pointer sp0 in

    (* ----- test code --- *)
    let argasserts = self#create_args_asserts finfo argconstraints in

    let unknown_scalar = env#mk_special_variable "unknown_scalar" in
    let initializeScalar =
      DOMAIN_OPERATION
        ([valueset_domain],
         {op_name = new symbol_t "set_unknown_scalar";
          op_args = [("unknown_scalar", unknown_scalar, WRITE)]}) in
    let initializeBasePointerOperations:cmd_t list =
      List.map (fun base ->
          DOMAIN_OPERATION
            ([valueset_domain],
             {op_name = new symbol_t "initialize";
              op_args = [(base#getName#getBaseName, base, READ)]}))
        finfo#get_base_pointers in
    let constantAssigns = env#end_transaction in
    let cmds =
      constantAssigns
      @ argasserts
      @ rAsserts
      @ mAsserts
      @ [ initializeScalar ]
      @ initializeBasePointerOperations in
    TRANSACTION (new symbol_t "entry", LF.mkCode cmds, None)

  method translate =
    let faddr = f#get_address in
    let firstInstrLabel = make_code_label funloc#ci in
    let entryLabel = make_code_label ~modifier:"entry" funloc#ci in
    let exitLabel = make_code_label ~modifier:"exit" funloc#ci in
    let procname = make_arm_proc_name faddr in
    let _ = f#iter self#translate_block in
    let argconstraints = system_info#get_argument_constraints faddr#to_hex_string in
    let entrycmd = self#get_entry_cmd argconstraints in
    let scope = finfo#env#get_scope in
    let _ = codegraph#add_node entryLabel [entrycmd] in
    let _ = codegraph#add_node exitLabel [SKIP] in
    let _ = codegraph#add_edge entryLabel firstInstrLabel in
    let cfg = codegraph#to_cfg entryLabel exitLabel in
    let body = LF.mkCode [CFG (procname, cfg)] in
    let proc = LF.mkProcedure procname [] [] scope body in
    (* let _ = pr_debug [ proc#toPretty; NL ] in *)
    arm_chif_system#add_arm_procedure proc

end

    
let translate_arm_assembly_function (f:arm_assembly_function_int) =
  let translator = new arm_assembly_function_translator_t f in
  try
    translator#translate
  with
  | CHFailure p
    | BCH_failure p ->
     let msg = LBLOCK [ STR "Failure in translation: "; p] in
     raise (BCH_failure msg)
