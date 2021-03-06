local driver = require 'pallene.driver'
local util = require 'pallene.util'

local function run_checker(code)
    -- "__test__.pln" does not exist on disk. The name is only used for error messages.
    local module, errs = driver.compile_internal("__test__.pln", code, "checker")
    return module, table.concat(errs, "\n")
end

local function assert_error(body, expected_err)
    local module, errs = run_checker(util.render([[
        local m: module = {}
        $body
        return m
    ]], {
        body = body
    }))
    assert.falsy(module)
    assert.match(expected_err, errs, 1, true)
end

describe("Scope analysis: ", function()

    it("forbids variables from being used before they are defined", function()
        assert_error([[
            function m.fn(): nil
                x = 17
                local x = 18
            end
        ]],
            "variable 'x' is not declared")
    end)

    it("forbids type variables from being used before they are defined", function()
        assert_error([[
            function m.fn(p: Point): integer
                return p.x
            end

            record Point
                x: integer
                y: integer
            end
        ]],
            "type 'Point' is not declared")
    end)

    it("do-end limits variable scope", function()
        assert_error([[
            function m.fn(): nil
                do
                    local x = 17
                end
                x = 18
            end
        ]],
            "variable 'x' is not declared")
    end)

    it("forbids multiple toplevel declarations with the same name for exported functions", function()
        assert_error([[
            function m.f() end
            function m.f() end
        ]],
            "multiple definitions for module field 'f'")
    end)

    it("forbids multiple toplevel declarations with the same name for exported function and constant", function()
        assert_error([[
            function m.f() end
            m.f = 1
        ]],
            "multiple definitions for module field 'f'")
    end)

    it("forbids multiple declarations for the same exported constant", function()
        assert_error([[
            m.x = 10
            m.x = 20
        ]],
            "multiple definitions for module field 'x'")
    end)

    it("forbids multiple declarations for the same exported constant in single statement", function()
        assert_error([[
            m.x, m.x = 10, 20
        ]],
            "multiple definitions for module field 'x'")
    end)

    it("ensure toplevel variables are not in scope in their initializers", function()
        assert_error([[
            local a = a
        ]],
            "variable 'a' is not declared")
    end)

    it("ensure toplevel exported variables are not in scope in their initializers", function()
        assert_error([[
            m.x = m.x
        ]],
            "module field 'x' does not exist")
    end)

    it("ensure variables are not in scope in their initializers", function()
        assert_error([[
            local function f()
                local a, b = 1, a
            end
        ]],
            "variable 'a' is not declared")
    end)

    it("ensure variables are not in scope in their initializers", function()
        assert_error([[
            local function f()
                local a = a
            end
        ]],
            "variable 'a' is not declared")
    end)

    it("forbids typealias to non-existent type", function()
        assert_error([[
            typealias point = foo
        ]],
            "type 'foo' is not declared")
    end)

    it("forbids recursive typealias", function()
        assert_error([[
            typealias point = {point}
        ]],
            "type 'point' is not declared")
    end)

    it("forbids typealias to non-type name", function()
        assert_error([[
            typealias point = x
            local x: integer = 0
        ]],
            "type 'x' is not declared")
    end)

    it("forbids setting a module constant outside of the toplevel", function()
        assert_error([[
            function m.f()
                m.x = 10
            end
        ]],
            "module fields can only be set at the toplevel")
    end)

    it("forbids setting a module function outside of the toplevel", function()
        assert_error([[
            function m.f()
                function m.g() end
            end
        ]],
            "module functions can only be set at the toplevel")
    end)

    it("cannot define function without local modifier", function()
        assert_error([[
            function f() : integer
                return 5319
            end
        ]],
            "function 'f' was not forward declared")
    end)

end)

describe("Pallene type checker", function()

    it('catches incompatible function type assignments', function()
        assert_error([[
            function m.f(a: integer, b: float): float
                return 3.14
            end

            function m.test(g: () -> integer)
                g = m.f
            end
        ]],
        "expected function type () -> (integer) but found function type (integer, float) -> (float) in assignment")
    end)

    it("detects when a non-type is used in a type variable", function()
        assert_error([[
            function m.fn()
                local foo: integer = 10
                local bar: foo = 11
            end
        ]],
            "'foo' is not a type")
    end)

    it("detects when a non-type is used in a type variable", function()
        assert_error([[
            function m.fn()
                local bar: m = 11
            end
        ]],
            "'m' is not a type")
    end)

    it("detects when a non-value is used in a value variable", function()
        assert_error([[
            record Point
                x: integer
                y: integer
            end

            function m.fn()
                local bar: integer = Point
            end
        ]],
            "'Point' is not a value")
    end)

    it("catches table type with repeated fields", function()
        assert_error([[
            function m.fn(t: {x: float, x: integer}) end
        ]],
            "duplicate field 'x' in table")
    end)

    it("allows tables with fields with more than LUAI_MAXSHORTLEN chars", function()
        local field = string.rep('a', 41)
        local module, _ = run_checker([[
            local m: module = {}
            function m.f(t: {]].. field ..[[: float}) end
            return m
        ]])
        assert.truthy(module)
    end)

    it("catches array expression in indexing is not an array", function()
        assert_error([[
            function m.fn(x: integer)
                x[1] = 2
            end
        ]],
            "expected array but found integer in array indexing")
    end)

    it("catches wrong use of length operator", function()
        assert_error([[
            function m.fn(x: integer): integer
                return #x
            end
        ]],
            "trying to take the length")
    end)

    it("catches wrong use of unary minus", function()
        assert_error([[
            function m.fn(x: boolean): boolean
                return -x
            end
        ]],
            "trying to negate a")
    end)

    it("catches wrong use of bitwise not", function()
        assert_error([[
            function m.fn(x: boolean): boolean
                return ~x
            end
        ]],
            "trying to bitwise negate a")
    end)

    it("catches wrong use of boolean not", function()
        assert_error([[
            function m.fn(): boolean
                return not nil
            end
        ]],
            "expression passed to 'not' operator has type nil")
    end)

    it("catches mismatching types in locals", function()
        assert_error([[
            function m.fn()
                local i: integer = 1
                local s: string = "foo"
                s = i
            end
        ]],
            "expected string but found integer in assignment")
    end)

    it("requires a type annotation for an uninitialized variable", function()
        assert_error([[
            function m.fn(): integer
                local x
                x = 10
                return x
            end
        ]], "uninitialized variable 'x' needs a type annotation")
    end)

    it("catches mismatching types in arguments", function()
        assert_error([[
            function m.fn(i: integer, s: string): integer
                s = i
            end
        ]],
            "expected string but found integer in assignment")
    end)

    it("forbids empty array (without type annotation)", function()
        assert_error([[
            function m.fn()
                local xs = {}
            end
        ]],
            "missing type hint for initializer")
    end)

    it("forbids non-empty array (without type annotation)", function()
        assert_error([[
            function m.fn()
                local xs = {10, 20, 30}
            end
        ]],
            "missing type hint for initializer")
    end)

    it("forbids array initializers with a table part", function()
        assert_error([[
            function m.fn()
                local xs: {integer} = {10, 20, 30, x=17}
            end
        ]],
            "named field 'x' in array initializer")
    end)

    it("forbids wrong type in array initializer", function()
        assert_error([[
            function m.fn()
                local xs: {integer} = {10, "hello"}
            end
        ]],
            "expected integer but found string in array initializer")
    end)

    it("type checks the iterator function in for-in loops", function()
        assert_error([[
            function m.fn()
                for k, v in 5, 1, 2 do
                    local a = k + v
                end
            end
        ]],
        "expected function type (any, any) -> (any, any) but found integer in loop iterator")

        assert_error([[
            function m.foo(a: integer, b: integer): integer
                return a * b
            end

            function m.fn()
                for k, v in m.foo, 1, 2 do
                    local a = k + v
                end
            end
        ]], "expected 1 variable(s) in for loop but found 2")
    end)

    it("type checks the state and control values of for-in loops", function()
        assert_error([[
            function m.foo(): (integer, integer)
                return 1, 2
            end

            function m.iter(a: any, b: any): (any, any)
                return 1, 2
            end

            function m.fn()
                for k, v in m.iter, m.foo() do
                    local a = k + v
                end
            end
        ]],
        "expected any but found integer in loop state value")

        assert_error([[
            function m.iter(a: any, b: any): (any, any)
                return 1, 2
            end

            function m.fn()
                for k, v in m.iter do
                    k = v
                end
            end
        ]], "missing state variable in for-in loop")

        assert_error([[
            function m.iter(a: any, b: any): (any, any)
                return 1, 2
            end

            function m.x_ipairs(): ((any, any) -> (any, any), integer)
                return m.iter, 4
            end

            function m.fn()
                for k, v in m.x_ipairs() do
                    k = v
                end
            end
        ]], "missing control variable in for-in loop")
    end)

    it("checks loops with ipairs.", function()
        assert_error([[
            function m.fn()
                for i: integer in ipairs() do
                    local x = i
                end
            end
        ]], "function expects 1 argument(s) but received 0")

        assert_error([[
            function m.fn()
                for i, x in ipairs({1, 2}, {3, 4}) do
                    local k = i
                end
            end
        ]], "function expects 1 argument(s) but received 2")

        assert_error([[
            function m.fn()
                for i, x, z in ipairs({1, 2}) do
                    local k = z
                end
            end
        ]], "expected 2 variable(s) in for loop but found 3")

        assert_error([[
            function m.fn()
                for i in ipairs({1, 2}) do
                    local k = z
                end
            end
        ]], "expected 2 variable(s) in for loop but found 1")
    end)


    describe("table/record initalizer", function()
        local function assert_init_error(typ, code, err)
            typ = typ and (": " .. typ) or ""
            assert_error([[
                record Point x: float; y:float end

                function m.f(): float
                    local p ]].. typ ..[[ = ]].. code ..[[
                end
            ]], err)
        end

        it("forbids creation without type annotation", function()
            assert_init_error(nil, [[ { x = 10.0, y = 20.0 } ]],
                "missing type hint for initializer")
        end)

        for _, typ in ipairs({"{ x: float, y: float }", "Point"}) do

            it("forbids wrong type in initializer", function()
                assert_init_error(typ, [[ { x = 10.0, y = "hello" } ]],
                    "expected float but found string in table initializer")
            end)

            it("forbids wrong field name in initializer", function()
                assert_init_error(typ, [[ { x = 10.0, y = 20.0, z = 30.0 } ]],
                    "invalid field 'z' in table initializer for " .. typ)
            end)

            it("forbids array part in initializer", function()
                assert_init_error(typ, [[ { x = 10.0, y = 20.0, 30.0 } ]],
                    "table initializer has array part")
            end)

            it("forbids initializing a field twice", function()
                assert_init_error(typ, [[ { x = 10.0, x = 11.0, y = 20.0 } ]],
                    "duplicate field 'x' in table initializer")
            end)

            it("forbids missing fields in initializer", function()
                assert_init_error(typ, [[ { y = 1.0 } ]],
                    "required field 'x' is missing")
            end)
        end
    end)

    it("forbids type hints that are not array, tables, or records", function()
        assert_error([[
            function m.fn()
                local p: string = { 10, 20, 30 }
            end
        ]],
            "type hint for initializer is not an array, table, or record type")
    end)

    it("requires while statement conditions to be boolean", function()
        assert_error([[
            function m.fn(x:integer): integer
                while x do
                    return 10
                end
                return 20
            end
        ]],
            "expression passed to while loop condition has type integer")
    end)

    it("requires repeat statement conditions to be boolean", function()
        assert_error([[
            function m.fn(x:integer): integer
                repeat
                    return 10
                until x
                return 20
            end
        ]],
            "expression passed to repeat-until loop condition has type integer")
    end)

    it("requires if statement conditions to be boolean", function()
        assert_error([[
            function m.fn(x:integer): integer
                if x then
                    return 10
                else
                    return 20
                end
            end
        ]],
            "expression passed to if statement condition has type integer")
    end)

    it("ensures numeric 'for' variable has number type", function()
        assert_error([[
            function m.fn(x: integer, s: string): integer
                for i: string = "hello", 10, 2 do
                    x = x + i
                end
                return x
            end
        ]],
            "expected integer or float but found string in for-loop control variable 'i'")
    end)

    it("catches 'for' errors in the start expression", function()
        assert_error([[
            function m.fn(x: integer, s: string): integer
                for i:integer = s, 10, 2 do
                    x = x + i
                end
                return x
            end
        ]],
            "expected integer but found string in numeric for-loop initializer")
    end)

    it("catches 'for' errors in the limit expression", function()
        assert_error([[
            function m.fn(x: integer, s: string): integer
                for i = 1, s, 2 do
                    x = x + i
                end
                return x
            end
        ]],
            "expected integer but found string in numeric for-loop limit")
    end)

    it("catches 'for' errors in the step expression", function()
        assert_error([[
            function m.fn(x: integer, s: string): integer
                for i = 1, 10, s do
                    x = x + i
                end
                return x
            end
        ]],
            "expected integer but found string in numeric for-loop step")
    end)

    it("detects too many return values", function()
        assert_error([[
            function m.f(): ()
                return 1
            end
        ]],
            "returning 1 value(s) but function expects 0")
    end)

    it("detects too few return values", function()
        assert_error([[
            function m.f(): integer
                return
            end
        ]],
            "returning 0 value(s) but function expects 1")
    end)

    it("detects too many return values when returning a function call", function()
        assert_error([[
            local function f(): (integer, integer)
                return 1, 2
            end

            function m.g(): integer
                return f()
            end
        ]],
            "returning 2 value(s) but function expects 1")
    end)

    it("detects when a function returns the wrong type", function()
        assert_error([[
            function m.fn(): integer
                return "hello"
            end
        ]],
            "expected integer but found string in return statement")
    end)

    it("rejects void functions in expression contexts", function()
        assert_error([[
            local function f(): ()
            end

            local function g(): integer
                return 1 + f()
            end
        ]],
            "void instead of a number")
    end)

    it("detects attempts to call non-functions", function()
        assert_error([[
            function m.fn(): integer
                local i: integer = 0
                i()
            end
        ]],
            "attempting to call a integer value")
    end)

    it("detects wrong number of arguments to functions", function()
        assert_error([[
            function m.f(x: integer, y: integer): integer
                return x + y
            end

            function m.g(): integer
                return m.f(1)
            end
        ]],
            "function expects 2 argument(s) but received 1")
    end)

    it("detects too few arguments when expanding a function", function()
        assert_error([[
            function m.f(): (integer, integer)
                return 1, 2
            end

            function m.g(x:integer, y:integer, z:integer): integer
                return x + y
            end

            function m.test(): integer
                return m.g(m.f())
            end
        ]],
            "function expects 3 argument(s) but received 2")
    end)

    it("detects too many arguments when expanding a function", function()
        assert_error([[
            function m.f(): (integer, integer)
                return 1, 2
            end

            function m.g(x:integer): integer
                return x
            end

            function m.test(): integer
                return m.g(m.f())
            end
        ]],
            "function expects 1 argument(s) but received 2")
    end)

    it("detects wrong types of arguments to functions", function()
        assert_error([[
            function m.f(x: integer, y: integer): integer
                return x + y
            end

            function m.g(): integer
                return m.f(1.0, 2.0)
            end
        ]],
            "expected integer but found float in argument 1 of call to function")
    end)

    describe("concatenation", function()
        for _, typ in ipairs({"boolean", "nil", "{ integer }"}) do
            local err_msg = string.format(
                "cannot concatenate with %s value", typ)
            local test_program = util.render([[
                function m.fn(x : $typ) : string
                    return "hello " .. x
                end
            ]], { typ = typ })

            it(err_msg, function()
                assert_error(test_program, err_msg)
            end)
        end
    end)


    local function optest(err_template, program_template, opts)
        local err_msg = util.render(err_template, opts)
        local test_program = util.render(program_template, opts)
        it(err_msg, function()
            assert_error(test_program, err_msg)
        end)
    end

    describe("equality:", function()
        local ops = { "==", "~=" }
        local typs = {
            "integer", "boolean", "float", "string", "{ integer }", "{ float }",
            "{ x: float }"
        }
        for _, op in ipairs(ops) do
            for _, t1 in ipairs(typs) do
                for _, t2 in ipairs(typs) do
                    if not (t1 == t2) and
                        not (t1 == "integer" and t2 == "float") and
                        not (t1 == "float" and t2 == "integer")
                    then
                        optest("cannot compare $t1 and $t2 using $op", [[
                            function m.fn(a: $t1, b: $t2): boolean
                                return a $op b
                             end
                        ]], {
                            op = op, t1 = t1, t2 = t2
                        })
                    end
                end
            end
        end
    end)

    describe("and/or:", function()
        for _, op in ipairs({"and", "or"}) do
            for _, t in ipairs({"{ integer }", "integer", "string"}) do
                for _, test in ipairs({
                    { "left", t, "boolean" },
                    { "right", "boolean", t },
                }) do
                    local dir, t1, t2 = test[1], test[2], test[3]
                    optest(
       "$dir hand side of '$op' has type $t", [[
                        function m.fn(x: $t1, y: $t2) : boolean
                            return x $op y
                        end
                    ]], { op = op, t = t, dir = dir, t1 = t1, t2=t2 })
                end
            end
        end
    end)

    describe("bitwise:", function()
        for _, op in ipairs({"|", "&", "<<", ">>"}) do
            for _, t in ipairs({"{ integer }", "boolean", "string"}) do
                for _, test in ipairs({
                    { "left", t, "integer" },
                    { "right", "integer", t },
                }) do
                    local dir, t1, t2 = test[1], test[2], test[3]
                    optest(
        "$dir hand side of bitwise expression is a $t instead of an integer", [[
                        function m.fn(a: $t1, b: $t2): integer
                            return a $op b
                        end
                    ]], { op = op, t = t, dir = dir, t1 = t1, t2 = t2 })
                end
            end
        end
    end)

    describe("arithmetic:", function()
        for _, op in ipairs({"+", "-", "*", "//", "/", "^"}) do
            for _, t in ipairs({"{ integer }", "boolean", "string"}) do
                for _, test in ipairs({
                    { "left", t, "float" },
                    { "right", "float", t },
                }) do
                    local dir, t1, t2 = test[1], test[2], test[3]
                    optest(
        "$dir hand side of arithmetic expression is a $t instead of a number", [[
                        function m.fn(a: $t1, b: $t2) : float
                            return a $op b
                        end
                    ]], { op = op, t = t, dir = dir, t1 = t1, t2 = t2} )
                end
            end
        end
    end)

    describe("dot", function()
        local function assert_dot_error(typ, code, err)
            assert_error([[
                record Point x: float; y:float end

                function m.f(p: ]].. typ ..[[): float
                    ]].. code ..[[
                end
            ]], err)
        end

        it("doesn't typecheck read/write to non indexable type", function()
            local err = "trying to access a member of a value of type 'string'"
            assert_dot_error("string", [[ ("t").x = 10 ]], err)
            assert_dot_error("string", [[ local x = ("t").x ]], err)
        end)

        for _, typ in ipairs({"{ x: float, y: float }", "Point"}) do
            it("doesn't typecheck read/write to non existent fields", function()
                local err = "field 'nope' not found in type '".. typ .."'"
                assert_dot_error(typ, [[ p.nope = 10 ]], err)
                assert_dot_error(typ, [[ return p.nope ]], err)
            end)

            it("doesn't typecheck read/write with invalid types", function()
                assert_dot_error(typ, [[ p.x = p ]],
                    "expected float but found ".. typ .." in assignment")
                assert_dot_error(typ, [[ local p: ]].. typ ..[[ = p.x ]],
                    "expected ".. typ .." but found float in declaration")
            end)
        end
    end)

    describe("casting:", function()
        local typs = {
            "boolean", "float", "integer", "nil", "string",
            "{ integer }", "{ float }", "{ x: float }",
        }
        for _, t1 in ipairs(typs) do
            for _, t2 in ipairs(typs) do
                if t1 ~= t2 then
                    optest("expected $t2 but found $t1 in cast expression", [[
                        function m.fn(a: $t1) : $t2
                            return a as $t2
                        end
                    ]], { t1 = t1, t2 = t2 })
                end
            end
        end
    end)

    it("catches assignment to function", function ()
        assert_error([[
            function m.f()
            end

            function m.g()
                m.f = m.g
            end
        ]],
        "module fields can only be set at the toplevel")
    end)

    it("catches assignment to builtin (with correct type)", function ()
        assert_error([[
            function m.f(x: string)
            end

            function m.g()
                io.write = m.f
            end
        ]],
        "LHS of assignment is not a mutable variable")
    end)

    it("catches assignment to builtin (with wrong type)", function ()
        assert_error([[
            function m.f(x: integer)
            end

            function m.g()
                io.write = m.f
            end
        ]],
        "LHS of assignment is not a mutable variable")
    end)

    it("typechecks io.write (error)", function()
        assert_error([[
            function m.f()
                io.write(17)
            end
        ]],
        "expected string but found integer in argument 1")
    end)

    it("checks assignment variables to modules", function()
        assert_error([[
            function m.f()
                local x = io
            end
        ]],
        "attempt to use module as a value")
    end)

    it("checks assignment of modules", function()
        assert_error([[
            function m.f()
                io = 1
            end
        ]],
        "attempt to use module as a value")
    end)

end)
