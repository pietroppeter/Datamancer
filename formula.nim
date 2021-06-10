import macros, tables, sequtils, sets, algorithm, options, strutils
import value, column, df_types
# formulaNameMacro contains a macro and type based on the fallback `FormulaNode`,
# which is used to generate the names of each `FormulaNode` in lisp representation
import formulaNameMacro
export formulaNameMacro

import formulaExp
export formulaExp

import arraymancer / laser / strided_iteration / foreach
export foreach

type
  FormulaNode* = object
    name*: string # stringification of whole formula. Only for printing and
                  # debugging
    case kind*: FormulaKind
    of fkVariable:
      # just some constant value. Result of a simple computation as a `Value`
      # This is mainly used to rename columns / provide a constant value
      val*: Value
    of fkAssign:
      lhs*: string # can this be something else?
      rhs*: Value
    of fkVector:
      colName*: string
      resType*: ColKind
      fnV*: proc(df: DataFrame): Column
    of fkScalar:
      valName*: string
      valKind*: ValueKind
      fnS*: proc(c: DataFrame): Value


func isColIdxCall(n: NimNode): bool =
  (n.kind == nnkCall and n[0].kind == nnkIdent and n[0].strVal in ["idx", "col"])
func isColCall(n: NimNode): bool =
  (n.kind == nnkCall and n[0].kind == nnkIdent and n[0].strVal == "col")
func isIdxCall(n: NimNode): bool =
  (n.kind == nnkCall and n[0].kind == nnkIdent and n[0].strVal == "idx")

proc isGeneric(n: NimNode): bool =
  ## given a node that represents a type, check if it's generic by checking
  ## if the symbol or bracket[symbol] is notin `Dtypes`
  case n.kind
  of nnkSym, nnkIdent: result = n.strVal notin Dtypes
  of nnkBracketExpr: result = n[1].strVal notin Dtypes
  else: error("Invalid call to `isGeneric` for non-type like node " &
    $(n.treeRepr) & "!")

func isLiteral(n: NimNode): bool = n.kind in {nnkIntLit .. nnkFloat64Lit, nnkStrLit}

func isScalar(n: NimNode): bool = n.strVal in Dtypes

proc reorderRawTilde(n: NimNode, tilde: NimNode): NimNode =
  ## a helper proc to reorder an nnkInfix tree according to the
  ## `~` contained in it, so that `~` is at the top tree.
  ## (the actual result is simply the tree reordered, but without
  ## the tilde. Reassembly must happen outside this proc)
  result = copyNimTree(n)
  for i, ch in n:
    case ch.kind
    of nnkIdent, nnkStrLit, nnkIntLit .. nnkFloat64Lit, nnkPar, nnkCall,
       nnkAccQuoted, nnkCallStrLit:
      discard
    of nnkInfix:
      if ch == tilde:
        result[i] = tilde[2]
      else:
        result[i] = reorderRawTilde(ch, tilde)
    else:
      error("Unsupported kind " & $ch.kind)

proc recurseFind(n: NimNode, cond: NimNode): NimNode =
  ## a helper proc to find a node matching `cond` recursively
  for i, ch in n:
    if ch == cond:
      result = n
      break
    else:
      let found = recurseFind(ch, cond)
      if found.kind != nnkNilLit:
        result = found

proc compileVectorFormula(fct: FormulaCT): NimNode =
  let fnClosure = generateClosure(fct)
  # given columns
  var colName = if fct.name.kind == nnkNilLit: newLit(fct.rawName) else: fct.name
  let dtype = fct.resType
  result = quote do:
    FormulaNode(name: `colName`,
                colName: `colName`, kind: fkVector,
                resType: toColKind(type(`dtype`)),
                fnV: `fnClosure`)
  echo result.repr

proc compileScalarFormula(fct: FormulaCT): NimNode =
  let fnClosure = generateClosure(fct)
  let valName = if fct.name.kind == nnkNilLit: newLit(fct.rawName) else: fct.name
  let rawName = fct.rawName
  let dtype = fct.resType
  result = quote do:
    FormulaNode(name: `rawName`,
                valName: `valName`, kind: fkScalar,
                valKind: toValKind(`dtype`),
                fnS: `fnClosure`)
  echo result.repr

proc checkDtype(body: NimNode,
                floatSet: HashSet[string],
                stringSet: HashSet[string],
                boolSet: HashSet[string]):
                  tuple[isFloat: bool,
                        isString: bool,
                        isBool: bool] =
  for i in 0 ..< body.len:
    case body[i].kind
    of nnkIdent:
      # check
      result = (isFloat: body[i].strVal in floatSet or result.isFloat,
                isString: body[i].strVal in stringSet or result.isString,
                isBool: body[i].strVal in boolSet or result.isBool)
    of nnkCallStrLit:
      # skip this node completely, don't traverse further, since it represents
      # a column!
      continue
    of nnkStrLit, nnkTripleStrLit, nnkRStrLit:
      result.isString = true
    of nnkIntLit .. nnkFloat64Lit:
      result.isFloat = true
    else:
      let res = checkDtype(body[i], floatSet, stringSet, boolSet)
      result = (isFloat: result.isFloat or res.isFloat,
                isString: result.isString or res.isString,
                isBool: result.isBool or res.isBool)

var TypedSymbols {.compileTime.}: Table[string, Table[string, NimNode]]
var Formulas {.compileTime.}: Table[string, FormulaCT]

macro addSymbols(tabName, nodeName: string, n: typed): untyped =
  let nStr = tabName.strVal
  let nodeStr = nodeName.strVal
  if nStr notin TypedSymbols:
    TypedSymbols[nStr] = initTable[string, NimNode]()
  TypedSymbols[nStr][nodeStr] = n

proc extractSymbols(n: NimNode): seq[NimNode] =
  case n.kind
  of nnkIdent, nnkSym:
    # take any identifier or symbol
    if n.strVal notin ["df", "idx"]: # these are reserved identifiers
      result.add n
  of nnkIntLit .. nnkFloat64Lit, nnkStrLit:
    result.add n
  of nnkBracketExpr:
    # check if contains df[<something>], df[<something>][idx]
    if not ((n[0].kind == nnkIdent and n[0].strVal == "df") or
            (n[0].kind == nnkBracketExpr and
             n[0][0].kind == nnkIdent and n[0][0].strVal == "df" and
             n[1].kind == nnkIdent and n[1].strVal == "idx")):
      result.add n
  of nnkDotExpr:
    ## If `DotExpr` consists only of Idents during the untyped pass,
    ## it's either field access or multiple calls taking no arguments.
    ## In that case we can just keep the chain and pass it to the typed
    ## macro. In case other things are contained (possibly `df[<...>]` or
    ## a regular call) take the individual fields.
    ## For something like `ms.trans` in ggplotnim (`trans` field of a scale)
    ## we need to pass `ms.trans` to typed macro!
    proc isAllIdent(n: NimNode): bool =
      result = true
      case n.kind
      of nnkIdent: discard
      of nnkDotExpr:
        if n[1].kind != nnkIdent: return false
        result = isAllIdent(n[0])
      else: return false
    let allIdent = isAllIdent(n)
    if allIdent:
      result.add n
    else:
      # add all identifiers found
      for ch in n:
        result.add extractSymbols(ch)
  of nnkCall:
    # check if it's a call of `idx(someCol)` or `col(someCol)`. Else recurse.
    if n.isColIdxCall():
      return
    for i in 0 ..< n.len:
      result.add extractSymbols(n[i])
  of nnkAccQuoted, nnkCallStrLit:
    # do not look at these, since they are untyped identifiers referring to
    # DF columns
    return
  else:
    for i in 0 ..< n.len:
      result.add extractSymbols(n[i])

proc determineHeuristicTypes(body: NimNode,
                             typeHint: TypeHint,
                             name: string): FormulaTypes =
  ## checks for certain ... to  determine both the probable
  ## data type for a computation and the `FormulaKind`
  doAssert body.len > 0, "Empty body unexpected in `determineFuncKind`!"
  # if more than one element, have to be a bit smarter about it
  # we use the following heuristics
  # - if `+, -, *, /, mod` involved, return as `float`
  #   `TODO:` can we somehow leave pure `int` calcs as `int`?
  # - if `&`, `$` involved, result is string
  # - if `and`, `or`, `xor`, `>`, `<`, `>=`, `<=`, `==`, `!=` involved
  #   result is considered `bool`
  # The priority of these is,
  # - 1. bool
  # - 2. string
  # - 3. float
  # which allows for something like
  # `"10." & "5" == $(val + 0.5)` as a valid bool expression
  # walk tree and check for symbols
  const floatSet = toHashSet(@["+", "-", "*", "/", "mod"])
  const stringSet = toHashSet(@["&", "$"])
  const boolSet = toHashSet(@["and", "or", "xor", ">", "<", ">=", "<=", "==", "!=",
                              "true", "false", "in", "notin"])
  let (isFloat, isString, isBool) = checkDtype(body, floatSet, stringSet, boolSet)
  var typ: TypeHint
  if isFloat:
    typ.inputType = some(ident"float")
    typ.resType = some(ident"float")
  if isString:
    # overrides float if it appears
    typ.inputType = some(ident"string")
    typ.resType = some(ident"string")
  if isBool:
    # overrides float and string if it appears
    if isString:
      typ.inputType = some(ident"string")
    elif isFloat:
      typ.inputType = some(ident"float")
    else:
      # is bool tensor
      typ.inputType = some(ident"bool")
    # result is definitely bool
    typ.resType = some(ident"bool")

  # apply typeHint if available (overrides above)
  if typeHint.inputType.isSome:
    let dtype = typeHint.inputType
    if isBool:
      # we don't override bool result type.
      # in cases like:
      # `f{int: x > 4}` the are sure of the result, apply to col only
      typ.inputType = dtype
    elif isFloat or isString:
      # override dtype, result still clear
      typ.inputType = dtype
    else:
      # set both
      typ.inputType = dtype
      typ.resType = dtype
  if typeHint.resType.isSome:
    # also assign result type. In this case override regardless of automatic
    # determination
    typ.resType = typeHint.resType
  if typ.inputType.isNone or typ.resType.isNone:
    # attempt via formula
    error("Could not determine data types of tensors in formula:\n" &
      "  name: " & $name & "\n" &
      "  formula: " & $body.repr & "\n" &
      "  data type: " & $typ.inputType.repr & "\n" &
      "  output data type: " & $typ.resType.repr & "\n" &
      "Consider giving type hints via: `f{T -> U: <theFormula>}`")

  result = FormulaTypes(inputType: typ.inputType.get, resType: typ.resType.get)

proc removeAll(s: string, chars: set[char]): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c notin chars:
      result.add c
  if result.len == 0:
    result = "col"

proc genColSym(name, s: string): NimNode =
  ## custom symbol generation from `name` (may contain characters that are
  ## invalid Nim symbols) and `s`
  let toRemove = AllChars - IdentStartChars
  var res = removeAll(name, toRemove)
  res &= s
  result = ident(res)

proc addColRef(n: NimNode, typeHint: FormulaTypes, asgnKind: AssignKind): seq[Assign] =
  let (dtype, resType) = (typeHint.inputType, typeHint.resType)
  case n.kind
  of nnkAccQuoted:
    let name = n[0].strVal
    result.add Assign(asgnKind: asgnKind,
                      element: ident(name & "Idx"),
                      tensor: ident(name),
                      col: newLit(name),
                      colType: dtype,
                      resType: resType)
  of nnkCallStrLit:
    # call str lit needs to be handled indendently, because it may contain
    # symbols that are invalid for a Nim identifier
    let name = buildFormula(n)
    let colName = genColSym(name, "T")
    let colIdxName = genColSym(name, "Idx")
    let nameCol = newLit(name)
    result.add Assign(asgnKind: asgnKind,
                      element: colIdxName,
                      tensor: colName,
                      col: nameCol,
                      colType: dtype,
                      resType: resType)
  of nnkBracketExpr:
    if nodeIsDf(n):
      # `df["someCol"]`
      let name = n[1]
      let colName = genColSym(buildFormula(name), "T")
      let colIdxName = genColSym(buildFormula(name), "Idx")
      result.add Assign(asgnKind: byTensor,
                        element: colIdxName,
                        tensor: colName,
                        col: n[1],
                        colType: dtype,
                        resType: resType)
    elif nodeIsDfIdx(n):
      # `df["someCol"][idx]`
      let name = n[0][1]
      let colName = genColSym(buildFormula(name), "T")
      let colIdxName = genColSym(buildFormula(name), "Idx")
      result.add Assign(asgnKind: byIndex,
                        element: colIdxName,
                        tensor: colName,
                        col: n[0][1],
                        colType: dtype,
                        resType: resType)
  of nnkCall:
    # - `col(someCol)` referring to full column access
    # - `idx(someCol)` referring to column index access
    let name = buildFormula(n[1])
    echo "NAME ", name.repr
    let colName = genColSym(name, "T")
    let colIdxName = genColSym(name, "Idx")
    echo colName.repr
    echo colIdxName.repr
    result.add Assign(asgnKind: asgnKind,
                      element: colIdxName,
                      tensor: colName,
                      col: n[1],
                      colType: dtype,
                      resType: resType)
  else:
    discard

proc countArgs(n: NimNode): tuple[args, optArgs: int] =
  ## counts the number of arguments this procedure has as well
  ## as the number of default arguments
  ## Arguments are a `nnkFormalParams`. The first child node refers
  ## to the return type.
  ## After that follows a bunch of `nnkIdentDefs`, with typically
  ## 3 child nodes. However if we have a proc
  ## `proc foo(a, b: int): int`
  ## the formal params only have 2 child nodes and a `nnkIdentDefs` with
  ## 4 instead of 3 children (due to the `,`).
  ## An optional value is stored in the last node. If no optional parameters
  ## that node is empty.
  expectKind(n, nnkFormalParams)
  # skip the first return type node
  for idx in 1 ..< n.len:
    let ch = n[idx]
    let chLen = ch.len
    inc result.args, chLen - 2 # add len - 2, since 3 by default.
                               #Any more is same type arg
    if ch[ch.len - 1].kind != nnkEmpty:
      inc result.optArgs, chLen - 2

proc typeAcceptableOrEmpty(n: NimNode): NimNode =
  ## Returns a type that either matches `Dtypes` (everything storable
  ## in a DF) or is a `Tensor[T]`. Returns that type.
  ## Otherwise returns an empty node.
  result = newEmptyNode()
  case n.kind
  of nnkIdent, nnkSym:
    if n.strVal in Dtypes:
      echo "TYPE IN DTYPES\n\n"
      result = n
  of nnkBracketExpr:
    if n[0].kind in {nnkSym, nnkIdent} and n[0].strVal == "Tensor":
      echo "TYPE IS TENSOR\n\n"
      result = n
  of nnkRefTy, nnkPtrTy, nnkInfix: discard
  else:
    error("Invalid type `" & $(n.treeRepr) & "`!")

type
  PossibleType = object
    isGeneric: bool
    typ: Option[NimNode]
    asgnKind: Option[AssignKind]
    resType: Option[NimNode]

proc typeToAsgnKind(n: NimNode): AssignKind =
  ## NOTE: only use this function if you know that `n` represents a
  ## `type` and it is either `Tensor[T]` or `T` where `T` has to be
  ## in `Dtypes` (DF allowed types)
  case n.kind
  of nnkBracketExpr: result = byTensor
  of nnkIdent, nnkSym: result = byIndex
  else: error("Invalid call to `typeToAsgnKind` for non-type like node " &
    $(n.treeRepr) & "!")

proc determineTypeFromProc(n: NimNode, arg, numArgs: int): PossibleType =
  # check if args matches our args
  result = PossibleType()
  let params = n.params
  let (hasNumArgs, optArgs) = countArgs(params)
  if (hasNumArgs - numArgs) <= optArgs and numArgs <= hasNumArgs:
    echo "PARAMS ", params.treeRepr, " arg ", arg
    let isGeneric = n[2].kind != nnkEmpty
    let pArg = params[arg] ## TODO: arg is wrong
    echo pArg.treeREpr
    let typ = typeAcceptableOrEmpty(pArg[pArg.len - 2]) # get second to last elment, which is type
    if typ.kind != nnkEmpty:
      echo n.repr
      let resType = params[0]
      result = PossibleType(isGeneric: isGeneric, typ: some(typ),
                            asgnKind: some(typeToAsgnKind(resType)),
                            resType: some(resType))

proc findType(n: NimNode, arg, numArgs: int): PossibleType =
  ## This procedure tries to find type information about a given NimNode.
  ## It must be a symbol (or contain one) of some kind. It should not be used for
  ## literals, as they have fixed type information.
  ## NOTE: this may be changed in the future! Currently this is used to

  ## TODO: this should be capable of determining something like
  ## `energies.min` to be `seq/Tensor[T] ⇒ T`!

  echo "NNN ", n.treerepr
  doAssert not n.isLiteral
  var possibleTypes = newSeq[PossibleType]()
  case n.kind
  of nnkSym:
    ## TODO: chck if a node referring to our types
    if n.strVal in Dtypes:
      result = PossibleType(isGeneric: false, typ: some(n), asgnKind: some(byIndex),
                            resType: some(n))
    else:
      ## TODO: check if a proc by using `getImpl`
      let tImpl = n.getImpl
      case tImpl.kind
      of nnkProcDef, nnkFuncDef:
        let pt = determineTypeFromProc(tImpl, arg, numArgs)
        if pt.typ.isSome:
          possibleTypes.add pt
      of nnkTemplateDef:
        # cannot deduce from template
        return
      else:
        error("How did we stumble over " & $(n.treeRepr) & " with type " &
          $(tImpl.treeRepr))
  of nnkCheckedFieldExpr:
    let impl = n.getTypeImpl
    expectKind(impl, nnkProcTy)
    let inputType = impl[0][1][1]
    let resType = impl[0][0]
    possibleTypes.add PossibleType(isGeneric: inputType.isGeneric,
                                   typ: some(inputType),
                                   asgnKind: some(typeToAsgnKind(resType)),
                                   resType: some(resType))
  of nnkClosedSymChoice, nnkOpenSymChoice:
    for ch in n:
      ## TODO: find union of all types
      let tImpl = ch.getImpl
      case tImpl.kind
      of nnkProcDef, nnkFuncDef:
        let pt = determineTypeFromProc(tImpl, arg, numArgs)
        if pt.typ.isSome:
          possibleTypes.add pt
      else:
        error("How did we stumble over " & $(ch.treeRepr) & " with type " &
          $(tImpl.treeRepr))
  else:
    echo "Found node of kind ", n.kind, "? ", n.repr
  if possibleTypes.len == 0:
    error("Invalid input. No possible types found in node: " & n.repr)
  var
    allTensor = true
    allScalar = true
    allGeneric = true
    noneGeneric = true
    inputType: NimNode
    resType: NimNode
  for pt in possibleTypes:
    doAssert pt.typ.isSome
    let typ = pt.typ.get
    allGeneric = allGeneric and pt.isGeneric
    noneGeneric = noneGeneric and (not pt.isGeneric)
    allTensor = allTensor and typ.kind == nnkBracketExpr
    allScalar = allScalar and typ.kind in {nnkSym, nnkIdent}
    ## TODO: WARNING we currently use the ``last`` type we encounter!! This does not
    ## make sense really!
    inputType = typ
    echo "RES TYPE bo ", resType.treeRepr
    resType = pt.resType.get
    echo "RES TYPE af ", resType.treeRepr
  if allGeneric and allTensor:
    ## return `handAsTensor`
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byTensor),
                          resType: some(resType))
  elif allGeneric and allScalar:
    ## return `handAsScalar`
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byIndex),
                          resType: some(resType))
  elif noneGeneric and allTensor:
    ## can determine a type, determine union type, else heuristic, `handAsTensor`
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byTensor),
                          resType: some(resType))
  elif noneGeneric and allScalar:
    ## can determine a type, determine union type, else heuristic, `handAsScalar`
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byIndex),
                          resType: some(resType))
    discard
  elif not (noneGeneric xor allGeneric) and allTensor:
    ## mixed generic and non generic. Overload cannot be used, need to
    ## rely on heuristics
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byTensor),
                          resType: some(resType))
  elif not (noneGeneric xor allGeneric) and allScalar:
    ## mixed generic and non generic. Overload cannot be used, need to
    ## rely on heuristics
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byIndex),
                          resType: some(resType))
  elif not (allTensor xor allScalar):
    ## assume `byIndex` for now
    warning("Ambiguous formula. Symbol `" & $(n.repr) & "` can take both a `Tensor[T]` " &
      "as well as `T`. Please use `df[\"foo\"]` to use overload taking a `Tensor[T]` " &
      "or `df[\"foo\"][idx]` to select overload taking a scalar!")
    result = PossibleType(isGeneric: true, typ: some(inputType), asgnKind: some(byIndex),
                          resType: some(resType))
  else:
    error("how?")
    error("Ambiguous formula. Symbol `" & $(n.repr) & "` can take both a `Tensor[T]` " &
      "as well as `T`. Please use `df[\"foo\"]` to use overload taking a `Tensor[T]` " &
      "or `df[\"foo\"][idx]` to select overload taking a scalar!")
  echo "Final type ", result.repr

proc determineTypesImpl(n: NimNode, tab: Table[string, NimNode],
                        heuristicType: FormulaTypes,
                        lastSym: string, arg: int, numArgs: var int): seq[Assign] =
  case n.kind
  of nnkCall, nnkCommand, nnkPrefix:  ## TODO: have to add nnkInfix
    if n.isColCall:
      result.add addColRef(n, heuristicType, byTensor)
    elif n.isIdxCall:
      result.add addColRef(n, heuristicType, byIndex)
    else:
      let lSym = buildFormula(n[0])
      numArgs = n.len - 1 # -1 cause first element is name of call
      echo "len  ", n.len
      for idx in 1 ..< n.len:
        echo "WALKING through ", n[idx].repr
        result.add determineTypesImpl(n[idx], tab, heuristicType, lSym, idx, numArgs)
      return result
  of nnkDotExpr:
    let lSym = buildFormula(n[1])
    numArgs = 1
    var asgns = determineTypesImpl(n[0], tab, heuristicType, lSym, 1, numArgs)
    # possibly fixup return type using `lSym` from here
    let nSym = tab[lSym]
    let posType = findType(nSym, arg, numArgs)
    if posType.resType.isSome:
      asgns[^1].resType = posType.resType.get
    result.add asgns
  of nnkAccQuoted, nnkCallStrLit, nnkBracketExpr:
    if lastSym.len == 0:
      result.add addColRef(n, heuristicType, byIndex)
    else:
      echo "Getting types for last sym ", lastSym, " and it ", n.repr
      let nSym = tab[lastSym]
      let posType = findType(nSym, arg, numArgs)
      let typ = if posType.typ.isSome:
                  FormulaTypes(inputType: posType.typ.get,
                               resType: posType.resType.get)
                else: heuristicType
      ## TODO: fix
      let asgn = if posType.asgnKind.isSome: posType.asgnKind.get else: byIndex
      echo "ASGN IN TYP ", asgn
      result.add addColRef(n, typ, asgn)
  else:
    for ch in n:
      result.add determineTypesImpl(ch, tab, heuristicType, lastSym, 1, numArgs)

proc determineTypes(loop: NimNode, tab: Table[string, NimNode],
                    heuristicType: FormulaTypes): Preface =
  var lastSym = ""
  var numArgs = 0
  let args = determineTypesImpl(loop, tab, heuristicType,
                                lastSym, 1, numArgs)
  result = Preface(args: args)

macro compileFormulaImpl*(rawName: untyped,
                          funcKind: untyped): untyped =
  ## This needs to be a macro, so that the calling code can add
  ## symbols to the `TypedSymbols` table before this macro runs!
  ## TODO: make use of CT information of all involved symbols for better type
  ## determination
  when false:
    ##
    for key, val in TypedSymbols:
      for ch in val:
        case ch.kind
        of nnkSym:
          echo ch.getImpl.repr
          echo ch.getType.repr
          echo "The symbol ", ch.treerepr
          #echo ch.getImpl[3][0].treeRepr
        of nnkClosedSymChoice, nnkOpenSymChoice:
          for chch in ch:
            echo chch.getType.repr
            echo chch.getImpl[3][0].treeRepr
            #echo chch.getImpl.treeRepr
        else:
          echo "Found node of kind ", ch.kind, "?"

  var fct = Formulas[rawName.strVal]
  #for k, v in TypedSymbols:
  #  echo k.repr
  #  for key, val in v:
  #    echo "\t", key.repr
  let typeTab = TypedSymbols[rawName.strVal]
  for k, v in typeTab:
    echo "\t", k, " ad v ", v.treeRepr
  var typ = determineHeuristicTypes(fct.loop, typeHint = fct.typeHint,
                                    name = fct.rawName)
  echo "LOOP ", fct.loop.treerepr
  echo "---"

  # generate the `preface`
  ## generating the preface is done by extracting all references to columns,
  ## using their names as `tensor` names (not element, since we in the general
  ## formula syntax can only refer to full columns)
  ## Explicit `df` usage (`df["col"][idx]` needs to be put into a temp variable,
  ## `genSym("col", nskVar)`)
  fct.preface = determineTypes(fct.loop, typeTab, typ)
  echo "PREFACE is ", fct.preface
  # compute the `resType`
  var resTypeFromSymbols: NimNode
  var allScalar = true
  for arg in mitems(fct.preface.args):
    if arg.colType.isGeneric:
      arg.colType = typ.inputType
    if arg.resType.isGeneric:
      resTypeFromSymbols = typ.resType
    if arg.asgnKind == byIndex:
      allScalar = false

  fct.resType = if resTypeFromSymbols.kind != nnkNilLit: resTypeFromSymbols
                else: typ.resType
  echo "RES TYPE ", fct.resType
  ## possibly overwrite funcKind
  fct.funcKind = if allScalar: fkScalar
                 else: FormulaKind(funcKind[1].intVal)

  when false:
    # possibly override formulaKind yet again due to `typeNodeTuples`
    if typeNodeTuples.len > 0 and allowOverride:
      # if a single `byValue` is involved, the output cannot be a scalar!
      mFuncKind = if typeNodeTuples.allIt(it[0] == byTensor): fkScalar
                  else: fkVector

  case fct.funcKind
  of fkVector: result = compileVectorFormula(fct)
  of fkScalar: result = compileScalarFormula(fct)
  else: error("Unreachable branch. `fkAssign` and `fkVariable` are already handled!")

  echo "******\n\n ",result.repr

proc parseTypeHint(n: var NimNode): TypeHint =
  case n.kind
  of nnkExprColonExpr:
    case n[0].kind
    of nnkIdent:
      # simple type hint for tensor input type
      result = TypeHint(inputType: some(n[0]))
      # resType is `None`
    of nnkInfix:
      doAssert n[0].len == 3
      doAssert eqIdent(n[0][0], ident"->")
      # type hint of tensor + result
      result = TypeHint(inputType: some(n[0][1]),
                        resType: some(n[0][2]))
    else: error("Unsupported type hint: " & $n[0].repr)
    n = copyNimTree(n[1])
  else: discard # no type hint

proc isPureFormula(n: NimNode): bool =
  result = true
  if n.len > 0:
    for ch in n:
      result = result and isPureFormula(ch)
      if not result:
        return result
  case n.kind
  of nnkAccQuoted, nnkCallStrLit: result = false
  of nnkBracketExpr:
    if nodeIsDf(n) or nodeIsDfIdx(n):
      result = false
  else: discard

proc compileFormula(n: NimNode): NimNode =
  var isAssignment = false
  var isReduce = false
  var isVector = false
  # extract possible type hint
  var node = n
  let typeHint = parseTypeHint(node)
  let tilde = recurseFind(node,
                          cond = ident"~")
  var formulaName = ""
  var formulaRhs = newNilLit()
  if tilde.kind != nnkNilLit and node[0].ident != toNimIdent"~":
    # only reorder the tree, if it does contain a tilde and the
    # tree is not already ordered (i.e. nnkInfix at top with tilde as
    # LHS)
    let replaced = reorderRawTilde(node, tilde)
    formulaName = buildFormula(tilde[1])
    formulaRhs = replaced
    isVector = true
  elif tilde.kind != nnkNilLit:
    # already tilde at level 0: infix(~, arg1, arg2)
    formulaName = buildFormula(node[1])
    formulaRhs = node[2]
    isVector = true
  else:
    # no tilde in node
    # check for `<-` assignment
    if node.len > 0 and eqIdent(node[0], ident"<-"):
      formulaName = buildFormula(node[1])
      formulaRhs = node[2]
      isAssignment = true
    # check for `<<` reduction
    elif node.len > 0 and eqIdent(node[0], ident"<<"):
      formulaName = buildFormula(node[1])
      formulaRhs = node[2]
      isReduce = true
    else:
      formulaRhs = node

  let fnName = buildFormula(node)
  let rawName = newLit fnName
  if isPureFormula(formulaRhs):
    # simply output a pure formula node
    if not isAssignment:
      ## TODO: allow in formulaExp.nim
      result = quote do:
        FormulaNode(kind: fkVariable,
                    name: `rawName`,
                    val: %~ `formulaRhs`)
    else:
      ## TODO: allow in formulaExp.nim
      result = quote do:
        FormulaNode(kind: fkAssign,
                    name: `rawName`,
                    lhs: `formulaName`,
                    rhs: %~ `formulaRhs`)
  else:
    ## The `funcKind` here is the ``preliminary`` determination of our
    ## FunctionKind. It may be overwritten at a later time in case the
    ## formula does not use explicit `~`, `<<` or `<-`, i.e. `f{<someOperation>}`
    ## without LHS.
    ## We have 2 pieces of information to go by
    ## -`df["<someCol>"]` in the body, refers to an operation on an explicit column,
    ##   -> should imply `fkScalar` (and has to be an arg of a proc call)
    ## - type information of all symbols that are not column references, which
    ##   might be reducing operations (`mean(df["someCol"])` etc.).
    let funcKind = if isAssignment: fkAssign
                   elif isReduce: fkScalar
                   elif isVector: fkVector
                   else: fkVector

    ## Generate a preliminary `FormulaCT` with the information we have so far
    var fct = FormulaCT()
    # assign the name
    fct.name = if formulaName.len == 0: newLit(fnName) else: newLit(formulaName)
    fct.rawName = fnName
    # assign the loop
    fct.loop = if formulaRhs.kind == nnkStmtList: formulaRhs
               else: newStmtList(formulaRhs)
    fct.typeHint = typeHint
    ## assign to global formula CT table
    echo "--------------------"
    echo fct.rawName
    echo fct.name
    echo "--------------------"
    Formulas[fct.rawName] = fct

    result = newStmtList()
    let syms = extractSymbols(formulaRhs)
    for s in syms:
      echo "@@@ ", s.repr, " and node ", s.treeRepr
    for s in syms:
      let sName = buildFormula(s)
      result.add quote do:
        addSymbols(`rawName`, `sName`, `s`)
    var cpCall = nnkCall.newTree(ident"compileFormulaImpl",
                                 rawName,
                                 newLit funcKind)
    result.add cpCall

macro `{}`*(x: untyped{ident}, y: untyped): untyped =
  ## TODO: add some ability to explicitly create formulas of
  ## different kinds more easily! Essentially force the type without
  ## a check to avoid having to rely on heuristics.
  ## Use
  ## - `<-` for assignment
  ## - `<<` for reduce operations, i.e. scalar proc?
  ## - `~` for vector like proc
  ## - formula without any of the above will be considered:
  ##   - `fkVariable` if no column involved
  ##   - `fkVector` else
  ## - `<type>: <actualFormula>`: simple type hint for tensors in closure
  ## - `<type> -> <resType>: <actualFormula>`: full type for closure.
  ##   `<type>` is the dtype used for tensors, `<resType>` the resulting type
  ## - `df[<someIdent/Sym>]`: to access columns using identifiers / symbols
  ##   defined in the scope
  ## - `idx`: can be used to access the loop iteration index
  if x.strVal == "f":
    result = compileFormula(y)

macro `fn`*(x: untyped): untyped =
  let arg = if x.kind == nnkStmtList: x[0] else: x
  doAssert arg.kind in {nnkCurly, nnkTableConstr}
  result = compileFormula(arg[0])