"""Parses and evaluates Cargo cfg predicates for Rust target triples."""

load(":cfg_target_data.bzl", "CFG_ATOMS", "CFG_ATOM_IDS_BY_TRIPLE")

def _emit_pending(frames, pending_ident, pending_eq_key):
    # Moves any pending identifier into a predicate node in the current frame.
    # If an '=' was seen but no string yet, that's a syntax error.
    if pending_eq_key:
        fail("cfg parse error: expected string literal after '=' for key '" + pending_eq_key[:-2] + "'.")
    if pending_ident:
        frames[len(frames)-1]["args"].append({"kind": "pred", "name": pending_ident})

############################################
# Tokenizer
############################################

# Tokens: IDENT(name), STRING(value), LPAREN, RPAREN, COMMA, EQ
def _cfg_tokenize(expr):
    tokens = []
    ident_buf = []
    str_buf = []
    in_string = False
    in_escape = False

    for ch in expr.elems():
        if in_string:
            if in_escape:
                str_buf.append(ch)
                in_escape = False
            elif ch == "\\":
                in_escape = True
            elif ch == "\"":
                tokens.append({"t": "STRING", "v": "".join(str_buf)})
                str_buf = []
                in_string = False
            else:
                str_buf.append(ch)
        else:
            if ch.isalpha() or ch == "_" or (ident_buf and ch.isdigit()):
                ident_buf.append(ch)
            else:
                if ident_buf != []:
                    tokens.append({"t": "IDENT", "v": "".join(ident_buf)})
                    ident_buf = []
                if ch == "(":
                    tokens.append({"t": "LPAREN"})
                elif ch == ")":
                    tokens.append({"t": "RPAREN"})
                elif ch == ",":
                    tokens.append({"t": "COMMA"})
                elif ch == "=":
                    tokens.append({"t": "EQ"})
                elif ch == "\"":
                    in_string = True
                # ignore whitespace/other

    if in_string:
        fail("cfg parse error: unterminated string literal.")
    if ident_buf:
        tokens.append({"t": "IDENT", "v": "".join(ident_buf)})
    return tokens


############################################
# Parser (non-recursive; stack of frames)
############################################

def cfg_parse(expr):
    """Parses a cfg predicate into its evaluator representation.

    Args:
      expr: The cfg predicate body to parse.

    Returns:
      A tuple containing the parsed syntax tree and whether it uses package
      feature cfgs.
    """
    tokens = _cfg_tokenize(expr)
    frames = [{"fn": "__ROOT__", "args": []}]
    pending_ident = None
    pending_eq_key = None
    uses_feature_cfg = False

    for t in tokens:
        kind = t["t"]
        if kind == "IDENT":
            pending_ident = t["v"]
        elif kind == "LPAREN":
            if not pending_ident:
                fail("cfg parse error: '(' not following identifier.")
            frames.append({"fn": pending_ident, "args": []})
            pending_ident = None
        elif kind == "EQ":
            if not pending_ident:
                fail("cfg parse error: '=' must follow a key identifier.")
            pending_eq_key = pending_ident
            pending_ident = None
        elif kind == "STRING":
            if not pending_eq_key:
                fail("cfg parse error: string literal not expected here.")
            if pending_eq_key == "feature":
                uses_feature_cfg = True
            frames[-1]["args"].append({
                "kind": "eq",
                "key": pending_eq_key,
                "value": t["v"],
            })
            pending_eq_key = None
        elif kind == "COMMA":
            _emit_pending(frames, pending_ident, pending_eq_key)
            pending_ident = None
        elif kind == "RPAREN":
            _emit_pending(frames, pending_ident, pending_eq_key)
            pending_ident = None
            closed = frames.pop()
            if not frames:
                fail("cfg parse error: too many closing ')'.")
            fname = closed["fn"]
            args_list = closed["args"]
            parent = frames[-1]["args"]
            if fname == "cfg":
                if len(args_list) != 1:
                    fail("cfg parse error: cfg(...) must contain a single expression.")
                parent.append(args_list[0])
            elif fname == "all":
                parent.append({"kind": "all", "args": args_list})
            elif fname == "any":
                parent.append({"kind": "any", "args": args_list})
            elif fname == "not":
                if len(args_list) != 1:
                    fail("cfg parse error: not(...) must have exactly one argument.")
                parent.append({"kind": "not", "args": args_list})
            else:
                fail("cfg parse error: unknown function '" + fname + "'.")
        else:
            fail("cfg parse error: unknown token kind.")

    _emit_pending(frames, pending_ident, pending_eq_key)
    pending_ident = None

    if len(frames) != 1:
        fail("cfg parse error: unbalanced parentheses.")

    root_args = frames[0]["args"]
    if len(root_args) != 1:
        if not root_args:
            fail("cfg parse error: empty expression.")
        fail("cfg parse error: multiple top-level expressions; wrap with all(...)/any(...).")

    return root_args[0], uses_feature_cfg

def _cfg_context(triple, atoms):
    ctx = {
        "_triple": triple,
        "true": True,
        "false": False,
    }
    for atom in atoms:
        pieces = atom.split("=", 1)
        if len(pieces) == 1:
            ctx[atom] = True
            continue

        key = pieces[0]
        encoded_value = pieces[1]
        value = encoded_value[1:-1]
        key_values = ctx.get(key)
        if key_values == None:
            key_values = set()
            ctx[key] = key_values
        key_values.add(value)
    return ctx

def cfg_atoms_for_triple(triple):
    atom_ids = CFG_ATOM_IDS_BY_TRIPLE.get(triple)
    if atom_ids == None:
        fail("Unsupported target triple '{}'; expected one of ALL_TARGET_TRIPLES".format(triple))
    return [CFG_ATOMS[atom_id] for atom_id in atom_ids]

def triple_to_cfg_attrs(triple):
    return _cfg_context(triple, cfg_atoms_for_triple(triple))

############################################
# Evaluator (non-recursive; explicit stack)
############################################

def _eval_eq(ctx, key, value, features):
    if key == "feature":
        return value in features
    return value in ctx.get(key, ())

def _eval_pred(ctx, name):
    return ctx.get(name, False)


def _cfg_eval(ast, ctx, features=[]):
    todo = [{"op": "VISIT", "node": ast}]
    results = []
    for _ in range(200000):
        if not todo:
            break
        instr = todo.pop()
        op = instr["op"]
        if op == "VISIT":
            node = instr["node"]
            kind = node["kind"]
            if kind == "pred":
                results.append(_eval_pred(ctx, node["name"]))
            elif kind == "eq":
                results.append(_eval_eq(ctx, node["key"], node["value"], features))
            else:
                children = node["args"]
                n = len(children)
                todo.append({"op": "REDUCE", "name": kind, "n": n})
                for child in reversed(children):
                    todo.append({"op": "VISIT", "node": child})
        else:  # REDUCE
            name = instr["name"]
            n = instr["n"]
            if name == "all":
                ok = True
                for _ in range(n):
                    if not results.pop():
                        ok = False
                results.append(ok)
            elif name == "any":
                ok = False
                for _ in range(n):
                    if results.pop():
                        ok = True
                results.append(ok)
            elif name == "not":
                if n != 1:
                    fail("cfg eval error: not(...) arity mismatch.")
                results.append(not results.pop())
            else:
                fail("cfg eval error: unknown op '" + name + "'.")
    if todo:
        fail("cfg eval error: internal traversal did not finish.")
    if len(results) != 1:
        fail("cfg eval error: unexpected result stack size.")
    return results[0]

def cfg_matches(expr, triple, features=[]):
    ast, _ = cfg_parse(expr)
    ctx = triple_to_cfg_attrs(triple)
    return _cfg_eval(ast, ctx, features)

def cfg_matches_expr_for_triples(expr, triples, features=[]):
    cfg_attrs = [triple_to_cfg_attrs(triple) for triple in triples]
    return cfg_matches_expr_for_cfg_attrs(expr, cfg_attrs, features)

def cfg_matches_expr_for_cfg_attrs(expr, cfg_attrs, features=[]):
    if expr.startswith("cfg("):
        ast, uses_feature_cfg = cfg_parse(expr)
        return struct(
            matches = cfg_matches_ast_for_triples(ast, cfg_attrs, features),
            uses_feature_cfg = uses_feature_cfg,
        )
    else:
        # Cargo target table keys that aren't cfg(...) are literal triples.
        return struct(
            matches = [cfg_attr["_triple"] for cfg_attr in cfg_attrs if cfg_attr["_triple"] == expr],
            uses_feature_cfg = False,
        )

def cfg_matches_ast_for_triples(ast, cfg_attrs, features=[]):
    return [cfg_attr["_triple"] for cfg_attr in cfg_attrs if _cfg_eval(ast, cfg_attr, features)]
