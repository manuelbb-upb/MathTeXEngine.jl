Base.@kwdef mutable struct NestingState
    ## TODO make immutable (and use Accessors.jl)? (then we don't have to define `hash` and `==`)
    #is_subscript :: Bool = false
    #is_superscript :: Bool = false
    disable_ssty :: Bool = false
    level :: UInt8 = 0
    scale :: Float32 = 1
end
function Base.hash(nesting_state::NestingState)
    return hash(
        #nesting_state.is_subscript, hash(
            #nesting_state.is_superscript, hash(
                nesting_state.disable_ssty, hash(
                    nesting_state.level, hash(
                        nesting_state.scale
                    )))#))
end
function Base.hash(nesting_state::NestingState, h::UInt)
    return hash(hash(nesting_state),h)
end
function Base.:(==)(nesting_state1::NestingState, nesting_state2::NestingState)
    return (
        #nesting_state1.is_subscript == nesting_state2.is_subscript &&
        #nesting_state1.is_superscript == nesting_state2.is_superscript &&
        nesting_state1.disable_ssty == nesting_state2.disable_ssty &&
        nesting_state1.level == nesting_state2.level &&
        nesting_state1.scale == nesting_state2.scale
    )
end

struct LayoutState
    font_family::FontFamily
    font_modifiers::Vector{Symbol}
    tex_mode::Symbol
    nesting_state::NestingState
end

LayoutState(font_family::FontFamily, modifiers::Vector) = LayoutState(font_family, modifiers, :text, NestingState())
LayoutState(font_family::FontFamily) = LayoutState(font_family, Symbol[])
LayoutState() = LayoutState(FontFamily())

function Base.show(io::IO, state::LayoutState)
    print(io, "LayoutState($(state.font_modifiers), $(state.tex_mode))")
end

Base.broadcastable(state::LayoutState) = Ref(state)

function change_mode(state::LayoutState, mode)
    LayoutState(state.font_family, state.font_modifiers, mode, state.nesting_state)
end

function add_font_modifier(state::LayoutState, modifier)
    modifiers = vcat(state.font_modifiers, modifier)
    return LayoutState(state.font_family, modifiers, state.tex_mode, state.nesting_state)
end

function new_script_state(state::LayoutState, scale=1; disable_ssty::Bool=false)
    nesting_state = deepcopy(state.nesting_state)
    nesting_state.level += 1
    nesting_state.scale *= scale   
    nesting_state.disable_ssty = disable_ssty
    return LayoutState(state.font_family, state.font_modifiers, state.tex_mode, nesting_state)
end

#=
function new_superscript_state(state::LayoutState, scale=1; override_is_superscript::Bool=true)
    nesting_state = deepcopy(state.nesting_state)
    nesting_state.is_superscript = override_is_superscript
    nesting_state.is_subscript = false
    nesting_state.level += 1
    nesting_state.scale *= scale
    return LayoutState(state.font_family, state.font_modifiers, state.tex_mode, nesting_state)
end

function new_subscript_state(state::LayoutState, scale=1)
    nesting_state = deepcopy(state.nesting_state)
    nesting_state.is_superscript = false
    nesting_state.is_subscript = true
    nesting_state.level += 1
    nesting_state.scale *= scale
    return LayoutState(state.font_family, state.font_modifiers, state.tex_mode, nesting_state)
end

function new_core_state(state::LayoutState, scale=1)
    nesting_state = deepcopy(state.nesting_state)
    nesting_state.is_superscript = false
    nesting_state.is_subscript = false
    return LayoutState(state.font_family, state.font_modifiers, state.tex_mode, nesting_state)
end
=#

function get_font(state::LayoutState, char_type)
    font_family = state.font_family
    font_id = get_font_id(state, char_type)
    return get_font(font_family, font_id)
end

function get_font_id(state::LayoutState, char_type)
    if state.tex_mode == :text
        char_type = :text
    end

    font_family = state.font_family
    font_id = font_family.font_mapping[char_type]

    for modifier in state.font_modifiers
        if haskey(font_family.font_modifiers, modifier)
            mapping = font_family.font_modifiers[modifier]
            font_id = get(mapping, font_id, font_id)
        else
            throw(ArgumentError("font modifier $modifier not supported for the current font family."))
        end
    end
    return font_id
end