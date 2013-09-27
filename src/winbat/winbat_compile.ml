open Core.Std
open Batsh_ast
open Winbat_ast

module Symbol_table = Batsh.Symbol_table

let rec compile_leftvalue
    (lvalue: Batsh_ast.leftvalue)
    ~(symtable: Symbol_table.t)
    ~(scope: Symbol_table.Scope.t)
  : leftvalue =
  match lvalue with
  | Identifier ident ->
    `Identifier ident
  | ListAccess (lvalue, index) ->
    let lvalue = compile_leftvalue lvalue ~symtable ~scope in
    let index = compile_expression_to_varint index ~symtable ~scope in
    `ListAccess (lvalue, index)

and compile_expression_to_varint
    (expr : Batsh_ast.expression)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : varint =
  match expr with
  | Leftvalue lvalue ->
    `Var (compile_leftvalue lvalue ~symtable ~scope)
  | Int num ->
    `Int num
  | _ ->
    failwith "Index should be either var or int"

let rec compile_expression_to_arith
    (expr : Batsh_ast.expression)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : arithmetic =
  match expr with
  | Bool false ->
    `Int 0
  | Bool true ->
    `Int 1
  | Int num ->
    `Int num
  | Leftvalue lvalue ->
    `Var (compile_leftvalue lvalue ~symtable ~scope)
  | ArithUnary (operator, expr) ->
    `ArithUnary (operator, compile_expression_to_arith expr ~symtable ~scope)
  | ArithBinary (operator, left, right) ->
    `ArithBinary (operator,
                  compile_expression_to_arith left ~symtable ~scope,
                  compile_expression_to_arith right ~symtable ~scope)
  | String _
  | Float _
  | List _
  | Concat _
  | StrCompare _
  | Call _ ->
    failwith "Can not be here"

let rec compile_expression
    (expr : Batsh_ast.expression)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : varstrings =
  match expr with
  | Bool false ->
    [`Str "0"]
  | Bool true ->
    [`Str "1"]
  | Int num ->
    [`Str (string_of_int num)]
  | String str ->
    [`Str str]
  | Leftvalue lvalue ->
    [`Var (compile_leftvalue lvalue ~symtable ~scope)]
  | Concat (left, right) ->
    let left = compile_expression left ~symtable ~scope in
    let right = compile_expression right ~symtable ~scope in
    left @ right
  | Call _ ->
    failwith "Not implemented: get stdout of given command"
  | _ ->
    assert false (* TODO *)

let compile_expressions
    (exprs : Batsh_ast.expressions)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : varstrings =
  List.concat (List.map exprs ~f: (compile_expression ~symtable ~scope))

let compile_expression_to_comparison
    (expr : Batsh_ast.expression)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : comparison =
  match expr with
  | StrCompare (operator, left, right)
  | ArithBinary (operator, left, right) ->
    let left = compile_expression left ~symtable ~scope in
    let right = compile_expression right ~symtable ~scope in
    `StrCompare (operator, left, right)
  | Leftvalue lvalue ->
    let lvalue = `Var (compile_leftvalue lvalue ~symtable ~scope) in
    `StrCompare ("==", [lvalue], [`Str "1"])
  | Bool true | Int 1 ->
    `StrCompare ("==", [`Str "1"], [`Str "1"])
  | Bool false | Int _ ->
    `StrCompare ("==", [`Str "0"], [`Str "1"])
  | _ ->
    failwith "Expression can not compile to comparison"

let rec compile_expression_statement
    (expr : Batsh_ast.expression)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : statement =
  match expr with
  | Call (ident, exprs) ->
    let exprs = compile_expressions exprs ~symtable ~scope in
    if Symbol_table.is_function symtable ident then
      `Call (`Str "call", [`Str ("call :" ^ ident); `Str "_"; `Str "0"] @ exprs)
    else
      (* external command *)
      `Call (`Str ident, exprs)
  | _ ->
    assert false (* TODO *)

let rec compile_statement
    (stmt : Batsh_ast.statement)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : statements =
  match stmt with
  | Comment comment ->
    [`Comment comment]
  | Block stmts ->
    compile_statements stmts ~symtable ~scope
  | Expression expr ->
    [compile_expression_statement expr ~symtable ~scope]
  | Assignment (lvalue, expr) ->
    compile_assignment lvalue expr ~symtable ~scope
  | If (expr, stmt) ->
    [`If (compile_expression_to_comparison expr ~symtable ~scope,
          compile_statement stmt ~symtable ~scope)]
  | IfElse (expr, then_stmt, else_stmt) ->
    [`IfElse (compile_expression_to_comparison expr ~symtable ~scope,
              compile_statement then_stmt ~symtable ~scope,
              compile_statement else_stmt ~symtable ~scope)]
  | While (expr, stmt) ->
    let condition = compile_expression_to_comparison expr ~symtable ~scope in
    let body = compile_statement stmt ~symtable ~scope in
    let label = sprintf "WHILE_%d" (Random.int 32768) in
    (* TODO check conflict *)
    [
      `Label label;
      `If (condition, body @ [`Goto label]);
    ]
  | Return (Some expr) ->
    [
      `Assignment (`Identifier "%~1", compile_expression expr ~symtable ~scope);
      `Goto ":EOF"
    ]
  | Return None ->
    [`Goto ":EOF"]
  | Global _
  | Empty ->
    []

and compile_assignment
    (lvalue : Batsh_ast.leftvalue)
    (expr : Batsh_ast.expression)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : statements =
  match expr with
  | String _
  | StrCompare _
  | Concat _
  | Call _
  | Leftvalue _ ->
    let lvalue = compile_leftvalue lvalue ~symtable ~scope in
    [`Assignment (lvalue, compile_expression expr ~symtable ~scope)]
  | Bool _
  | Int _
  | Float _
  | ArithUnary _
  | ArithBinary _ ->
    let lvalue = compile_leftvalue lvalue ~symtable ~scope in
    [`ArithAssign (lvalue, compile_expression_to_arith expr ~symtable ~scope)]
  | List exprs ->
    List.concat (List.mapi exprs ~f: (fun i expr ->
        compile_assignment (ListAccess (lvalue, (Int i))) expr ~symtable ~scope
      ))

and compile_statements
    (stmts: Batsh_ast.statements)
    ~(symtable: Symbol_table.t)
    ~(scope: Symbol_table.Scope.t)
  :statements =
  List.fold stmts ~init: [] ~f: (fun acc stmt ->
      let stmts = compile_statement stmt ~symtable ~scope in
      acc @ stmts
    )

let rec compile_function_leftvalue
    (lvalue : leftvalue)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : leftvalue =
  match lvalue with
  | `Identifier ident ->
    (* TODO global variable *)
    `ListAccess (lvalue, `Var (`Identifier "%~2"))
  | `ListAccess (lvalue, index) ->
    `ListAccess (compile_function_leftvalue lvalue ~symtable ~scope, index)

let compile_function_varstring
    (var : varstring)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : varstring =
  match var with
  | `Var lvalue ->
    `Var (compile_function_leftvalue lvalue ~symtable ~scope)
  | `Str _ ->
    var

let compile_function_varstrings
    (vars : varstrings)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : varstrings =
  List.map vars ~f: (compile_function_varstring ~symtable ~scope)

let rec compile_function_arithmetic
    (arith : arithmetic)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : arithmetic =
  match arith with
  | `Var lvalue ->
    `Var (compile_function_leftvalue lvalue ~symtable ~scope)
  | `Int _ ->
    arith
  | `ArithUnary (operator, arith) ->
    `ArithUnary (operator, compile_function_arithmetic arith ~symtable ~scope)
  | `ArithBinary (operator, left, right) ->
    `ArithBinary (operator,
                  compile_function_arithmetic left ~symtable ~scope,
                  compile_function_arithmetic right ~symtable ~scope)

let compile_function_comparison
    (cond : comparison)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : comparison =
  match cond with
  | `StrCompare (operator, left, right) ->
    `StrCompare (operator,
                 compile_function_varstrings left ~symtable ~scope,
                 compile_function_varstrings right ~symtable ~scope)

let rec compile_function_statement
    (stmt : statement)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : statement =
  match stmt with
  | `Comment _ | `Raw _ | `Label _ | `Goto _ | `Empty ->
    stmt
  | `Assignment (lvalue, vars) ->
    `Assignment (compile_function_leftvalue lvalue ~symtable ~scope,
                 compile_function_varstrings vars ~symtable ~scope)
  | `ArithAssign (lvalue, arith) ->
    `ArithAssign (compile_function_leftvalue lvalue ~symtable ~scope,
                  compile_function_arithmetic arith ~symtable ~scope)
  | `Call (name, params) ->
    `Call (compile_function_varstring name ~symtable ~scope,
           compile_function_varstrings params ~symtable ~scope)
  | `If (cond, stmts) ->
    `If (compile_function_comparison cond ~symtable ~scope,
         compile_function_statements stmts ~symtable ~scope)
  | `IfElse (cond, then_stmts, else_stmts) ->
    `IfElse (compile_function_comparison cond ~symtable ~scope,
             compile_function_statements then_stmts ~symtable ~scope,
             compile_function_statements else_stmts ~symtable ~scope)

and compile_function_statements
    (stmts : statements)
    ~(symtable : Symbol_table.t)
    ~(scope : Symbol_table.Scope.t)
  : statements =
  List.map stmts ~f: (compile_function_statement ~symtable ~scope)

let compile_function
    (name, params, stmts)
    ~(symtable : Symbol_table.t)
  : statements =
  let scope = Symbol_table.scope symtable name in
  let body = compile_statements stmts ~symtable ~scope in
  let replaced_body = compile_function_statements body ~symtable ~scope in
  let params_assignments : statements = List.mapi params ~f: (fun i param ->
      let lvalue : leftvalue = `ListAccess (`Identifier param, `Var (`Identifier "%~2")) in
      `Assignment (lvalue,
                   [`Var (`Identifier (sprintf "%%~%d" (i + 3)))])
    )
  in
  ((`Goto ":EOF") :: (`Label name) :: params_assignments) @ replaced_body

let compile_toplevel
    ~(symtable : Symbol_table.t)
    (topl: Batsh_ast.toplevel)
  : statements =
  match topl with
  | Statement stmt ->
    compile_statement stmt ~symtable
      ~scope: (Symbol_table.global_scope symtable)
  | Function func ->
    compile_function func ~symtable

let sort_functions (topls : Batsh_ast.t) : Batsh_ast.t =
  let is_function topl : bool =
    match topl with
    | Function _ -> true
    | Statement _ -> false
  in
  List.sort topls ~cmp: (fun a b ->
      let func_a = is_function a in
      let func_b = is_function b in
      if func_a then
        if func_b then
          0
        else
          1
      else
      if func_b then
        -1
      else
        0
    )

let compile (batsh: Batsh.t) : t =
  let ast = Batsh.ast batsh in
  let symtable = Batsh.symtable batsh in
  let transformed_ast = Winbat_transform.split ast ~symtable in
  let sorted_ast = sort_functions transformed_ast in
  let stmts = List.fold sorted_ast ~init: [] ~f: (fun acc topl ->
      let stmts = compile_toplevel topl ~symtable in
      acc @ stmts
    ) in
  (`Raw "@echo off")
  :: (`Raw "setlocal EnableDelayedExpansion")
  :: (`Raw "setlocal EnableExtensions")
  :: stmts
