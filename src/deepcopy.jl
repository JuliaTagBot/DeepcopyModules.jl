function deepcopy_module(m::Module)
    m2 = Module(nameof(m), true)
    import_names_into(m2, m)
    setparent!(m2, parentmodule(m))
    return m2
end

usings(m::Module) =
    ccall(:jl_module_usings, Array{Module,1}, (Any,), m)

_full_using_name(modu) = Expr(:., fullname(modu)...)
_import_name_expr(val) = _import_name_expr(parentmodule(val), nameof(val))
_import_name_expr(modu::Module, name::Symbol) = Expr(:(:), _full_using_name(modu), Expr(:., name))

function import_names_into(destmodule, srcmodule)
    for m in usings(srcmodule)
        Core.eval(destmodule, Expr(:using, _full_using_name(m)))
    end
    imports = names(srcmodule, imported=true)
    # don't copy itself into itself; don't copy `include`, define it below instead
    excluded_names = (nameof(srcmodule), Symbol("#include"), :include)
    imports = setdiff(imports, excluded_names)
    for n in imports
        srcval = Core.eval(srcmodule, n)
        if srcval isa Module
            Core.eval(destmodule, Expr(:import, _full_using_name(srcval)))
        else
            #@show srcmodule, n, typeof(srcval)
            try
                # Try importing from the original source module
                Core.eval(destmodule, Expr(:import, _import_name_expr(srcval)))
            catch
                # Otherwise, import from srcmodule directly
                Core.eval(destmodule, Expr(:import, _import_name_expr(srcmodule, n)))
            end
        end
    end
    ns = setdiff(names(srcmodule, all=true), imports)
    ns = setdiff(ns, excluded_names)
    # Do definitions bottom up to get `Symbol("#foo")` kw defs last
    for n in reverse(ns)
        srcval = Core.eval(srcmodule, n)
        #@show destmodule, srcmodule, n, typeof(srcval)
        @eval destmodule $n = $srcval
        deepcopy_value(destmodule, srcmodule, n, srcval)
    end
    @eval destmodule include(fname::AbstractString) = Main.Base.include(@__MODULE__, fname)
end


# Make new names w/ a copy of the value. For functions, make a new function object.
deepcopy_value(destmodule, srcmodule, name, value) = Core.eval(destmodule, :($name = $(deepcopy(value))))
function deepcopy_value(destmodule, srcmodule, name, value::Function)
    deepcopy_function(destmodule, value)
end
function deepcopy_value(destmodule, srcmodule, name, value::Module)
    m2 = deepcopy_module(value)
    setparent!(m2, destmodule)
    m2
end
# Shallow-copy these as references for now
deepcopy_value(destmodule, srcmodule, name,
               value::Union{Base.Docs.Binding, IdDict}) = Core.eval(destmodule, :($name = $(value)))

# Manually implement "missing" julia Base function to allow setting the parent of a module.
function setparent!(m::Module, p::Module)
    unsafe_store!(Ptr{_Module2}(pointer_from_objref(m)),
                   _Module2(nameof(m), p), 1)
    m
end
# NOTE: This struct must be kept up-to-date with Julia's `_jl_module_t`!
struct _Module2
    name::Symbol
    parent::Module
end
