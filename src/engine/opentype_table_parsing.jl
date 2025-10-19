# Utilities to read (parts of) the MATH table stored in OpenType Math fonts
# See 
# https://learn.microsoft.com/en-us/typography/opentype/spec/math
# https://freetype.org/freetype2/docs/reference/ft2-truetype_tables.html
module OpenTypeTableParsing

import FreeTypeAbstraction: FreeType, FTFont, check_error
import FreeTypeAbstraction.FreeType: libfreetype, FT_Face, FT_Error, FT_ULong, FT_Long, 
    FT_UInt32, FT_Byte, FT_FWord, FT_UFWord

const FT_TAG = FT_UInt32

const CURSOR = UInt32   # guessed, should be good for up to 4 GiB font-files

const ENGINE_SUPPORTED_FEATURE_TAGS = ("ssty",)

## originally a macro in freetype
"Return a numeric tag to obtain an SNFT table for a fontface."
function FT_MAKE_TAG(_x1, _x2, _x3, _x4)
    return convert(FT_TAG, (
        ( convert( FT_TAG, _x1 ) << 24 ) | 
        ( convert( FT_TAG, _x2 ) << 16 ) | 
        ( convert( FT_TAG, _x3 ) <<  8 ) | 
        convert( FT_TAG, _x4 )         
    ))
end

const TTAG_MATH = FT_MAKE_TAG('M','A','T','H')
const TTAG_GSUB = FT_MAKE_TAG('G','S','U','B')

struct GSUBHeader
    major_version :: UInt16
    minor_version :: UInt16
    script_list_offset :: UInt16
    feature_list_offset :: UInt16
    lookup_list_offset :: UInt16
    feature_variations_offset :: Union{UInt32, Nothing}
end

function GSUBHeader(buffer::IOBuffer)
    seekstart(buffer)
    major_version = read(buffer, UInt16) |> ntoh
    minor_version = read(buffer, UInt16) |> ntoh
    script_list_offset = read(buffer, UInt16) |> ntoh
    feature_list_offset = read(buffer, UInt16) |> ntoh
    lookup_list_offset = read(buffer, UInt16) |> ntoh
    feature_variations_offset = if major_version == 1 && minor_version == 1
        read(buffer, UInt32) |> ntoh
    else
        nothing
    end
    return GSUBHeader(major_version, minor_version, 
        script_list_offset, feature_list_offset, lookup_list_offset, 
        feature_variations_offset)
end

struct FeatureRecord
    tag :: String
    offset :: UInt16

    cursor :: CURSOR
end

struct FeatureList
    feature_count :: UInt16
    feature_records :: Vector{FeatureRecord}

    cursor :: CURSOR
end

function FeatureList(
    buffer::IOBuffer, header::GSUBHeader=GSUBHeader(buffer))
    # https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#featurelist-table
    
    seek(buffer, header.feature_list_offset)
    feature_count = read(buffer, UInt16) |> ntoh
    feature_records = FeatureRecord[]
    for _=1:feature_count
        cursor = position(buffer)
        tag = mapreduce(
            _ -> Char(read(buffer, UInt8)), *, 1:4)
        offset = read(buffer, UInt16) |> ntoh
        push!(feature_records, FeatureRecord(tag, offset, cursor))
    end
    return FeatureList(
        feature_count, feature_records, header.feature_list_offset)
end

struct FeatureTable
    # https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#feature-table
    feature_params_offset :: UInt16
    lookup_index_count :: UInt16
    lookup_list_indices :: Vector{UInt16}

    cursor :: CURSOR
end

function FeatureTable(
    buffer::IOBuffer, 
    feature_list::FeatureList,
    feature_record::FeatureRecord
)
    cursor = feature_list.cursor + feature_record.offset
    seek(buffer, cursor) 
    feature_params_offset = read(buffer, UInt16) |> ntoh
    lookup_index_count = read(buffer, UInt16) |> ntoh
    lookup_list_indices = [ntoh(read(buffer, UInt16)) for _=1:lookup_index_count]
    return FeatureTable(
        feature_params_offset, lookup_index_count, lookup_list_indices, cursor)
end

struct LookupList
    lookup_count :: UInt16
    lookup_offsets :: Vector{UInt16}

    cursor :: CURSOR
end

function LookupList(
    buffer::IOBuffer, header::GSUBHeader=GSUBHeader(buffer))
    cursor = header.lookup_list_offset
    seek(buffer, cursor)
    lookup_count = read(buffer, UInt16) |> ntoh
    lookup_offsets = [ntoh(read(buffer, UInt16)) for _=1:lookup_count]
    return LookupList(lookup_count, lookup_offsets, cursor)
end

struct LookupTable
    lookup_type :: UInt16
    lookup_flag :: UInt16
    sub_table_count :: UInt16
    subtable_offsets :: Vector{UInt16}
    mark_filtering_set :: Union{Nothing, UInt16}

    cursor :: CURSOR
end

function LookupTable(
    buffer::IOBuffer, 
    lookup_list::LookupList=LookupList(buffer),
    lookup_list_index::Integer=0    # zero-based, from FeatureTable -> lookup_list_indices
)
    cursor = lookup_list.cursor + lookup_list.lookup_offsets[lookup_list_index + 1]
    seek(buffer, cursor)
    lookup_type = read(buffer, UInt16) |> ntoh
    lookup_flag = read(buffer, UInt16) |> ntoh
    sub_table_count = read(buffer, UInt16) |> ntoh
    subtable_offsets = [ntoh(read(buffer, UInt16)) for _=1:sub_table_count]
    mark_filtering_set = if lookup_flag & 0x0010 == 0x0010
        read(buffer, UInt16) |> ntoh
    else
        nothing
    end
    return LookupTable(
        lookup_type, lookup_flag,
        sub_table_count, subtable_offsets, mark_filtering_set, cursor)
end

struct SingleSubstitutionTable1
    format :: UInt16 # == 1
    delta_glyph_id :: Int16

    cursor :: CURSOR
end

struct SingleSubstitutionTable2
    format :: UInt16 # == 2
    glyph_count :: UInt16
    substitute_glyph_ids :: Vector{UInt16}

    cursor :: CURSOR
end

struct LookupSubTable1
    # https://learn.microsoft.com/en-us/typography/opentype/spec/gsub#lookup-type-1-subtable-single-substitution 
    format :: UInt16 # in (1, 2)
    coverage_offset :: UInt16
    table :: Union{SingleSubstitutionTable1, SingleSubstitutionTable2}

    cursor :: CURSOR
end

function LookupSubTable1(
    buffer::IOBuffer,
    lookup_table::LookupTable,
    subtable_index::Integer # one-based
)
    subtable_offset = lookup_table.subtable_offsets[subtable_index]
    cursor = lookup_table.cursor + subtable_offset
    seek(buffer, cursor)
    format = read(buffer, UInt16) |> ntoh
    @assert format == 1 || format == 2 "Unexpected SubTable `format` (`format = $(format)`, expected `format in (1, 2)`)."
    coverage_offset = read(buffer, UInt16) |> ntoh
    table = if format == 1
        delta_glyph_id = read(buffer, Int16) |> ntoh
        SingleSubstitutionTable1(format, delta_glyph_id, cursor)
    else
        glyph_count = read(buffer, UInt16) |> ntoh
        substitute_glyph_ids = [ntoh(read(buffer, UInt16)) for _=1:glyph_count]
        SingleSubstitutionTable2(format, glyph_count, substitute_glyph_ids, cursor)
    end
        
    return LookupSubTable1(
        format, coverage_offset, table, cursor) 
end

struct LookupSubTable3 # Alternate substitution format 1
    # https://learn.microsoft.com/en-us/typography/opentype/spec/gsub#lookup-type-3-subtable-alternate-substitution
    format :: UInt16    # == 1
    coverage_offset :: UInt16
    alternate_set_count :: UInt16
    alternate_set_offsets :: Vector{UInt16}

    cursor :: UInt16
end

function LookupSubTable3(
    buffer::IOBuffer,
    lookup_table::LookupTable,
    subtable_index::Integer # one-based
)
    subtable_offset = lookup_table.subtable_offsets[subtable_index]
    cursor = lookup_table.cursor + subtable_offset
    seek(buffer, cursor)
    format = read(buffer, UInt16) |> ntoh
    @assert format == 1 "Unexpected SubTable `format` (`format = $(format)`, expected `format == 1`)."
    coverage_offset = read(buffer, UInt16) |> ntoh
    alternate_set_count = read(buffer, UInt16) |> ntoh
    alternate_set_offsets = [ntoh(read(buffer, UInt16)) for _=1:alternate_set_count]
    return LookupSubTable3(
        format, coverage_offset, alternate_set_count, alternate_set_offsets, cursor)
end

const LOOKUP_SUB_TABLE = Union{LookupSubTable1, LookupSubTable3}

function LookupSubTable(
    buffer::IOBuffer,
    lookup_table::LookupTable,
    subtable_index::Integer
)
    if lookup_table.lookup_type == 1
        return LookupSubTable1(buffer, lookup_table, subtable_index)
    elseif lookup_table.lookup_type == 3
        return LookupSubTable3(buffer, lookup_table, subtable_index)
    end
    @debug "Lookup-SubTable format $(Int(lookup_table.lookup_type)) not supported (yet)."
    return nothing
end

struct CoverageTable1
    # https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#coverage-format-1
    format :: UInt16 # == 1
    glyph_count :: UInt16 
    glyph_array :: Vector{UInt16}

    cursor :: CURSOR
end

struct RangeRecord
    start_glyph_id :: UInt16
    end_glyph_id :: UInt16
    start_coverage_index :: UInt16

    cursor :: CURSOR
end

struct CoverageTable2
    # https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#coverage-format-2
    format :: UInt16 # == 2
    range_count :: UInt16
    range_records :: Vector{RangeRecord}

    cursor :: CURSOR
end

const COVERAGE_TABLE = Union{CoverageTable1, CoverageTable2}

function CoverageTable(
    buffer::IOBuffer,
    lookup_subtable::LOOKUP_SUB_TABLE,
) :: COVERAGE_TABLE
    cursor = lookup_subtable.cursor + lookup_subtable.coverage_offset
    seek(buffer, cursor)
    format = read(buffer, UInt16) |> ntoh
    @assert format == 1 || format == 2 "Unexpected Coverage Format (must equal 1 or 2)."
    if format == 1
        glyph_count = read(buffer, UInt16) |> ntoh
        glyph_array = [ntoh(read(buffer, UInt16)) for _=1:glyph_count]
        return CoverageTable1(format, glyph_count, glyph_array, cursor)
    end
    range_count = read(buffer, UInt16) |> ntoh
    range_records = RangeRecord[]
    for _=1:range_count
        range_cursor = position(buffer)
        range_record = RangeRecord(
            ntoh(read(buffer, UInt16)),
            ntoh(read(buffer, UInt16)),
            ntoh(read(buffer, UInt16)),
            range_cursor
        )
        push!(range_records, range_record)
    end
    return CoverageTable2(format, range_count, range_records, cursor)
end

function _coverage_index(
    glyph_id::Integer,
    coverage_table::CoverageTable1,
)
    ## one-based
    (coverage_table.glyph_count <= 0) && return nothing
    glyph_range = searchsorted(coverage_table.glyph_array, glyph_id)
    isempty(glyph_range) && return nothing
    return first(glyph_range)   # `only` should work too
end

function _coverage_index(
    glyph_id::Integer,
    coverage_table::CoverageTable2,
)
    ## one-based
    coverage_index = nothing
    (coverage_table.range_count <= 0) && return coverage_index
    for range_record in coverage_table.range_records
        start_glyph_id = range_record.start_glyph_id
        if start_glyph_id <= glyph_id <= range_record.end_glyph_id
            coverage_index = range_record.start_coverage_index + glyph_id - start_glyph_id + 1
            break
        end
    end 
    return coverage_index
end

struct AlternateSet
    glyph_count :: UInt16
    alternate_glyph_ids :: Vector{UInt16}

    cursor :: CURSOR
end

function AlternateSet(
    buffer::IOBuffer,
    lookup_subtable::LookupSubTable3,
    coverage_index::Integer
)
    cursor = lookup_subtable.cursor + lookup_subtable.alternate_set_offsets[coverage_index]
    seek(buffer, cursor)
    glyph_count = read(buffer, UInt16) |> ntoh
    alternate_glyph_ids = [ntoh(read(buffer, UInt16)) for _=1:glyph_count]
    return AlternateSet(glyph_count, alternate_glyph_ids, cursor)
end

function _subs_glyph_indices(
    buffer::IOBuffer, lookup_subtable::LOOKUP_SUB_TABLE, coverage_table::COVERAGE_TABLE, glyph_id::Integer,
    sub_index=1
)
    coverage_index = _coverage_index(glyph_id, coverage_table)
    isnothing(coverage_index) && return glyph_id
    return __subs_glyph_indices(buffer, lookup_subtable, glyph_id, coverage_index, sub_index)
end

function __subs_glyph_indices(
    buffer::IOBuffer, lookup_subtable::LookupSubTable3, glyph_id::G, coverage_index, sub_index
) :: Union{G, UInt16} where {G}
    aset = AlternateSet(buffer, lookup_subtable, coverage_index)
    sub_index = min(sub_index, length(aset.alternate_glyph_ids))
    return aset.alternate_glyph_ids[sub_index]
end

function __subs_glyph_indices(
    buffer::IOBuffer, lookup_subtable::LookupSubTable1, glyph_id, coverage_index, sub_index
)
    return ___subs_glyph_indices(buffer, lookup_subtable.table, glyph_id, coverage_index)
end

function ___subs_glyph_indices(
    buffer::IOBuffer, lookup_subtable::SingleSubstitutionTable1, glyph_id, coverage_index
)
    nid = glyph_id + lookup_subtable.delta_glyph_id % typemax(UInt16)  # TODO check if correct, https://learn.microsoft.com/en-us/typography/opentype/spec/gsub#lookup-type-1-subtable-single-substitution
    return nid
end

function ___subs_glyph_indices(
    buffer::IOBuffer, lookup_subtable::SingleSubstitutionTable2, glyph_id, coverage_index
)
    nid = lookup_subtable.substitute_glyph_ids[coverage_index]
    return nid
end

Base.@kwdef mutable struct SSTYData
    face :: FTFont
    buffer :: Union{Nothing, Missing, IOBuffer} = nothing
    header :: Union{Nothing, GSUBHeader} = nothing
    feature_list :: Union{Nothing, FeatureList} = nothing
    lookup_list :: Union{Nothing, LookupList} = nothing
    feature_table :: Union{Nothing, FeatureTable} = nothing
    lookup_tables :: Union{Nothing, Vector{LookupTable}} = nothing
    lookup_subtable_dict :: Union{Nothing, Dict{LookupTable, Vector{Union{Missing, LOOKUP_SUB_TABLE}}}} = nothing
    coverage_table_dict :: Union{Nothing, Dict{LOOKUP_SUB_TABLE, COVERAGE_TABLE}} = nothing
end

function _ssty_glyph_id(
    ssty_data::SSTYData,
    glyph_id::Integer,
    subscript_level=1
)
    feature_tag = "ssty"
    
    if isnothing(ssty_data.buffer)
        ssty_data.buffer = _get_snft_table_buffer(ssty_data.face, TTAG_GSUB; throw_error=false)
        if isnothing(ssty_data.buffer)
            ssty_data.buffer = missing
        end
    end
    buffer = ssty_data.buffer
    ismissing(buffer) && return glyph_id

    if isnothing(ssty_data.header)
        ssty_data.header = GSUBHeader(buffer)
    end
    header = ssty_data.header

    if isnothing(ssty_data.lookup_list)
        ssty_data.lookup_list = LookupList(buffer, header)
    end
    lookup_list = ssty_data.lookup_list

    if isnothing(ssty_data.feature_list)
        ssty_data.feature_list = FeatureList(buffer, header)
    end
    feature_list = ssty_data.feature_list
    j = 0
    for (i, feature_record) in enumerate(feature_list.feature_records)
        if feature_record.tag == feature_tag
            j = i
            break
        end
    end
    if iszero(j)
        @debug "`_ssty_glyph_id`: Feature tag `$(feature_tag)` not supported by font."
        return glyph_id
    end
    feature_record = feature_list.feature_records[j]
    
    if isnothing(ssty_data.feature_table)
        ssty_data.feature_table = FeatureTable(buffer, feature_list, feature_record)
    end
    feature_table = ssty_data.feature_table
    
    if isnothing(ssty_data.lookup_tables)
        ssty_data.lookup_tables = [
            LookupTable(buffer, lookup_list, i) for i = feature_table.lookup_list_indices
        ]
    end
    lookup_tables = ssty_data.lookup_tables

    if isnothing(ssty_data.lookup_subtable_dict)
        ssty_data.lookup_subtable_dict = Dict{LookupTable, Vector{Union{Missing, LOOKUP_SUB_TABLE}}}()
    end
    lookup_subtable_dict = ssty_data.lookup_subtable_dict
    
    for lt in lookup_tables
        if !haskey(lookup_subtable_dict, lt)
            lookup_subtable_dict[lt] = [
                let st=LookupSubTable(buffer, lt, i);
                    isnothing(st) ? missing : st
                end for i = 1:lt.sub_table_count 
            ]
        end
    end

    if isnothing(ssty_data.coverage_table_dict)
        ssty_data.coverage_table_dict = Dict{LOOKUP_SUB_TABLE, COVERAGE_TABLE}()
    end
    coverage_table_dict = ssty_data.coverage_table_dict
    
    alt_glyph_id = glyph_id
    for lt in lookup_tables
        for st in lookup_subtable_dict[lt]
            ismissing(st) && continue
            coverage_table = get!(coverage_table_dict, st) do
                CoverageTable(buffer, st)
            end
            alt_glyph_id = _subs_glyph_indices(buffer, st, coverage_table, glyph_id, subscript_level)
        end
    end
    return alt_glyph_id
end

struct MathHeaderTable
    major_version :: UInt16
    minor_version :: UInt16
    math_constants_offset :: UInt16
    math_glyph_info_offset :: UInt16
    math_variants_offset :: UInt16
end

function MathHeaderTable(buffer::IOBuffer)
    seekstart(buffer)
    major_version = read(buffer, UInt16) |> ntoh
    minor_version = read(buffer, UInt16) |> ntoh
    math_constants_offset = read(buffer, UInt16) |> ntoh
    math_glyph_info_offset = read(buffer, UInt16) |> ntoh
    math_math_variants_offset = read(buffer, UInt16) |> ntoh
    return MathHeaderTable(
        major_version, minor_version, math_constants_offset, math_glyph_info_offset, math_math_variants_offset
    )
end

struct MathValueRecord
    value :: FT_FWord
    offset :: UInt16
end

struct MathTable
    face :: FTFont
    buffer :: IOBuffer
    header :: MathHeaderTable
    constants :: Dict{Symbol, Union{Int16, FT_UFWord, MathValueRecord}}
end

function Base.show(io::IO, mtable::MathTable)
    print(io, "MathTable (with constants $(length(mtable.constants)))")
end

function MathTable(face::FTFont; throw_error::Bool=true)
    buffer = _get_math_table_buffer(face; throw_error)
    if isnothing(buffer)
        return buffer
    end
    header = MathHeaderTable(buffer)
    constants = _read_math_constants(buffer, header)
    return MathTable(face, buffer, header, constants)
end

function get_math_constant(::Nothing, symb, default, scaled=true)
    return default
end
function get_math_constant(mtab::MathTable, symb, default, scaled=true)
    v = get(mtab.constants, symb, nothing)
    isnothing(v) && return default
    if isa(v, MathValueRecord)
        v = v.value
        if scaled
            v /= mtab.face.units_per_EM
        end
    end
    return v
end

function _get_math_table_buffer(face::FTFont; throw_error::Bool=true)
    global TTAG_MATH
    return _get_snft_table_buffer(face, TTAG_MATH; throw_error)
end

function _get_snft_table_buffer(face::FTFont, tag::FT_TAG; throw_error::Bool=true)
    offset = 0
    length = Ref(zero(UInt64))
    buffer = Ptr{Cvoid}()

    ## first call, determine length
    err = @lock face.lock ccall(
        (:FT_Load_Sfnt_Table, libfreetype), 
        FT_Error, 
        (FT_Face, FT_TAG, FT_Long, Ptr{FT_Byte}, Ptr{FT_ULong},),
        face, tag, offset, buffer, length 
    )
    if err != 0
        if throw_error
            error("Could not load table (tag = $(tag)), error code = $(err).")
        else
            return nothing
        end
    end
    
    ## allocate memory for second call to actually load the table
    n = Int(length[])
    buffer = Vector{FT_Byte}(undef, n)
    err = @lock face.lock ccall(
        (:FT_Load_Sfnt_Table, libfreetype), 
        FT_Error, 
        (FT_Face, FT_TAG, FT_Long, Ptr{FT_Byte}, Ptr{FT_ULong},),
        face, tag, offset, buffer, length 
    )
    if err != 0
        if throw_error
            error("Could not load MATH table, error code = $(err).")
        else
            return nothing
        end
    end
     
    return IOBuffer(buffer)
end

function _read_math_constants(buffer::IOBuffer, header::MathHeaderTable)
    constants = Dict{Symbol, Union{Int16, FT_UFWord, MathValueRecord}}()

    seek(buffer, header.math_constants_offset)

    constants[:scriptPercentScaleDown] = read(buffer, Int16) |> ntoh
    constants[:scriptScriptPercentScaleDown] = read(buffer, Int16) |> ntoh

    constants[:delimitedSubFormulaMinHeight] = read(buffer, FT_UFWord) |> ntoh
    constants[:displayOperatorMinHeight] = read(buffer, FT_UFWord) |> ntoh

    constants[:mathLeading] = _read_math_value_record(buffer)
    constants[:axisHeight] = _read_math_value_record(buffer)
    constants[:accentBaseHeight] = _read_math_value_record(buffer)
    constants[:flattenedAccentBaseHeight] = _read_math_value_record(buffer)
    constants[:subscriptShiftDown] = _read_math_value_record(buffer)
    constants[:subscriptTopMax] = _read_math_value_record(buffer)
    constants[:subscriptBaselineDropMin] = _read_math_value_record(buffer)
    constants[:superscriptShiftUp] = _read_math_value_record(buffer)
    constants[:superscriptShiftUpCramped] = _read_math_value_record(buffer)
    constants[:superscriptBottomMin] = _read_math_value_record(buffer)
    constants[:superscriptBaselineDropMax] = _read_math_value_record(buffer)
    constants[:subSuperscriptGapMin] = _read_math_value_record(buffer)
    constants[:superscriptBottomMaxWithSubscript] = _read_math_value_record(buffer)
    constants[:spaceAfterScript] = _read_math_value_record(buffer)
    constants[:upperLimitGapMin] = _read_math_value_record(buffer)
    constants[:upperLimitBaselineRiseMin] = _read_math_value_record(buffer)
    constants[:lowerLimitGapMin] = _read_math_value_record(buffer)
    constants[:lowerLimitBaselineDropMin] = _read_math_value_record(buffer)
    constants[:stackTopShiftUp] = _read_math_value_record(buffer)
    constants[:stackTopDisplayStyleShiftUp] = _read_math_value_record(buffer)
    constants[:stackBottomShiftDown] = _read_math_value_record(buffer)
    constants[:stackBottomDisplayStyleShiftDown] = _read_math_value_record(buffer)
    constants[:stackGapMin] = _read_math_value_record(buffer)
    constants[:stackDisplayStyleGapMin] = _read_math_value_record(buffer)
    constants[:stretchStackTopShiftUp] = _read_math_value_record(buffer)
    constants[:stretchStackBottomShiftDown] = _read_math_value_record(buffer)
    constants[:stretchStackGapAboveMin] = _read_math_value_record(buffer)
    constants[:stretchStackGapBelowMin] = _read_math_value_record(buffer)
    constants[:fractionNumeratorShiftUp] = _read_math_value_record(buffer)
    constants[:fractionNumeratorDisplayStyleShiftUp] = _read_math_value_record(buffer)
    constants[:fractionDenominatorShiftDown] = _read_math_value_record(buffer)
    constants[:fractionDenominatorDisplayStyleShiftDown] = _read_math_value_record(buffer)
    constants[:fractionNumeratorGapMin] = _read_math_value_record(buffer)
    constants[:fractionNumDisplayStyleGapMin] = _read_math_value_record(buffer)
    constants[:fractionRuleThickness] = _read_math_value_record(buffer)
    constants[:fractionDenominatorGapMin] = _read_math_value_record(buffer)
    constants[:fractionDenomDisplayStyleGapMin] = _read_math_value_record(buffer)
    constants[:skewedFractionHorizontalGap] = _read_math_value_record(buffer)
    constants[:skewedFractionVerticalGap] = _read_math_value_record(buffer)
    constants[:overbarVerticalGap] = _read_math_value_record(buffer)
    constants[:overbarRuleThickness] = _read_math_value_record(buffer)
    constants[:overbarExtraAscender] = _read_math_value_record(buffer)
    constants[:underbarVerticalGap] = _read_math_value_record(buffer)
    constants[:underbarRuleThickness] = _read_math_value_record(buffer)
    constants[:underbarExtraDescender] = _read_math_value_record(buffer)
    constants[:radicalVerticalGap] = _read_math_value_record(buffer)
    constants[:radicalDisplayStyleVerticalGap] = _read_math_value_record(buffer)
    constants[:radicalRuleThickness] = _read_math_value_record(buffer)
    constants[:radicalExtraAscender] = _read_math_value_record(buffer)
    constants[:radicalKernBeforeDegree] = _read_math_value_record(buffer)
    constants[:radicalKernAfterDegree] = _read_math_value_record(buffer)

    constants[:radicalDegreeBottomRaisePercent] = read(buffer, Int16) |> ntoh

    return constants
end

function _read_math_value_record(buffer)
    value = read(buffer, FT_FWord) |> ntoh
    offset = read(buffer, UInt16) |> ntoh
    return MathValueRecord(value, offset)
end

end#module