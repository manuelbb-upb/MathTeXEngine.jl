
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
    cursor_for_offset :: CURSOR
end

struct FeatureList
    feature_count :: UInt16
    feature_records :: Vector{FeatureRecord}

    cursor :: CURSOR
end

function FeatureList(
    buffer::IOBuffer, header::GSUBHeader=GSUBHeader(buffer))
    # https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#featurelist-table
    fl_cursor = header.feature_list_offset
    seek(buffer, header.feature_list_offset)
    feature_count = read(buffer, UInt16) |> ntoh
    feature_records = FeatureRecord[]
    for _=1:feature_count
        cursor = position(buffer)
        tag = mapreduce(
            _ -> Char(read(buffer, UInt8)), *, 1:4)
        offset = read(buffer, UInt16) |> ntoh
        push!(feature_records, FeatureRecord(tag, offset, cursor, fl_cursor))
    end
    return FeatureList(
        feature_count, feature_records, fl_cursor)
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
    @assert feature_list.cursor == feature_record.cursor_for_offset
    return FeatureTable(buffer, feature_record.cursor_for_offset, feature_record.offset)
end

function FeatureTable(
    buffer::IOBuffer, 
    feature_record::FeatureRecord
)
    return FeatureTable(buffer, feature_record.cursor_for_offset, feature_record.offset)
end

function FeatureTable(
    buffer::IOBuffer,
    cursor_for_offset::Integer,
    offset::Integer
)
    cursor = cursor_for_offset + offset
    return FeatureTable(buffer, cursor)
end

function FeatureTable(
    buffer::IOBuffer,
    cursor::Integer
)
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

function LookupTables(
    buffer::IOBuffer,
    feature_table::FeatureTable,
    lookup_list::LookupList=LookupList(buffer),
)
    return [
        LookupTable(buffer, lookup_list, ind) for ind = feature_table.lookup_list_indices
    ]
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
    if !(format == 1 || format == 2)
        @debug "`LookupSubTable1`: Unexpected SubTable `format` (`format = $(format)`, expected `format in (1, 2)`)."
        return nothing
    end
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
    if format != 1 
        @debug "`LookupSubTable3`: Unexpected SubTable `format` (`format = $(format)`, expected `format == 1`)."
        return nothing
    end
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
    if !(format == 1 || format == 2)
        @debug "`CoverageTable`: Unexpected Coverage Format (must equal 1 or 2)."
        return nothing
    end
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

function _subs_glyph_index(
    buffer::IOBuffer, lookup_subtable::LOOKUP_SUB_TABLE, coverage_table::COVERAGE_TABLE, glyph_id::Integer,
    sub_index=1; default=glyph_id
)
    coverage_index = _coverage_index(glyph_id, coverage_table)
    isnothing(coverage_index) && return default
    return __subs_glyph_index(buffer, lookup_subtable, glyph_id, coverage_index, sub_index)
end

function __subs_glyph_index(
    buffer::IOBuffer, lookup_subtable::LookupSubTable3, glyph_id, coverage_index, sub_index
)
    aset = AlternateSet(buffer, lookup_subtable, coverage_index)
    sub_index = max(1, min(sub_index, length(aset.alternate_glyph_ids)))
    return aset.alternate_glyph_ids[sub_index] :: UInt16
end

function __subs_glyph_index(
    buffer::IOBuffer, lookup_subtable::LookupSubTable1, glyph_id, coverage_index, sub_index
)
    return ___subs_glyph_index(buffer, lookup_subtable.table, glyph_id, coverage_index)
end

function ___subs_glyph_index(
    buffer::IOBuffer, lookup_subtable::SingleSubstitutionTable1, glyph_id, coverage_index
)
    nid = glyph_id + lookup_subtable.delta_glyph_id % typemax(UInt16)  # TODO check if correct, https://learn.microsoft.com/en-us/typography/opentype/spec/gsub#lookup-type-1-subtable-single-substitution
    return UInt16(nid)
end

function ___subs_glyph_index(
    buffer::IOBuffer, lookup_subtable::SingleSubstitutionTable2, glyph_id, coverage_index
)
    nid = lookup_subtable.substitute_glyph_ids[coverage_index] :: UInt16
    return nid
end

Base.@kwdef mutable struct SSTYData
    face :: FTFont
    buffer :: Union{Nothing, Missing, IOBuffer} = missing
    header :: Union{Nothing, GSUBHeader} = nothing
    lookup_tables :: Union{Nothing, Vector{LookupTable}} = nothing
    lookup_subtable_dict :: Union{Nothing, Dict{LookupTable, Vector{Union{Nothing, LOOKUP_SUB_TABLE}}}} = nothing
    coverage_table_dict :: Union{Nothing, Dict{LOOKUP_SUB_TABLE, Union{Nothing, COVERAGE_TABLE}}} = nothing
end

function _ssty_glyph_id(
    ssty_data::SSTYData,
    glyph_id::Integer,
    subscript_level::Integer=1
)
    
    buffer = _upget_buffer!(ssty_data)
    header = _upget_header!(ssty_data)
    
    lookup_tables = _upget_lookup_tables!(ssty_data)
    lookup_subtable_dict = _upget_lookup_subtable_dict!(ssty_data)
    coverage_table_dict = _upget_coverage_table_dict!(ssty_data)
    
    return __loopsubs_glyph_id(buffer, lookup_tables, lookup_subtable_dict, coverage_table_dict, glyph_id, subscript_level)
end

function _upget_buffer!(ssty_data)
    if ismissing(ssty_data.buffer)
        ssty_data.buffer = _get_snft_table_buffer(ssty_data.face, TTAG_GSUB; throw_error=false)
        for fn in (
            :header, 
            :lookup_tables, :lookup_subtable_dict, :coverage_table_dict
        )
            setfield!(ssty_data, fn, nothing)
        end
    end
    return ssty_data.buffer
end

function _upget_header!(ssty_data)
    __upget_header!(ssty_data, ssty_data.buffer, ssty_data.header)
end
__upget_header!(ssty_data, buffer, header)=header
function __upget_header!(ssty_data, buffer::IOBuffer, header::Nothing)
    header = ssty_data.header = GSUBHeader(buffer)
    return header
end

function _upget_lookup_tables!(ssty_data)
    __upget_lookup_tables!(ssty_data, ssty_data.buffer, ssty_data.header, ssty_data.lookup_tables)
end
__upget_lookup_tables!(ssty_data, buffer, header, lookup_tables)=lookup_tables
function __upget_lookup_tables!(ssty_data, buffer::IOBuffer, header::GSUBHeader, lookup_tables::Nothing)
    lookup_list = LookupList(buffer, header)
    feature_record = nothing
    feature_list = FeatureList(buffer, header)
    for _feature_record in feature_list.feature_records
        if _feature_record.tag == "ssty"
            feature_record = _feature_record :: FeatureRecord 
            break
        end
    end
    isnothing(feature_record) && return LookupTable[]
    feature_table = FeatureTable(buffer, feature_record)
    lookup_tables = ssty_data.lookup_tables = LookupTables(buffer, feature_table, lookup_list)
    return lookup_tables
end

function _upget_lookup_subtable_dict!(ssty_data)
    return __upget_lookup_subtable_dict!(
        ssty_data, ssty_data.buffer, ssty_data.lookup_tables, ssty_data.lookup_subtable_dict)
end
__upget_lookup_subtable_dict!(ssty_data, buffer, lookup_tables, lookup_subtable_dict)=lookup_subtable_dict
function __upget_lookup_subtable_dict!(
    ssty_data, buffer::IOBuffer, lookup_tables::Vector, lookup_subtable_dict::Nothing
)   
    lookup_subtable_dict = ssty_data.lookup_subtable_dict = Dict{LookupTable, Vector{Union{Nothing, LOOKUP_SUB_TABLE}}}()

    for lt in lookup_tables
        if !haskey(lookup_subtable_dict, lt)
            lookup_subtable_dict[lt] = [
                LookupSubTable(buffer, lt, i) for i=1:lt.sub_table_count ]
        end
    end
    return lookup_subtable_dict
end

function _upget_coverage_table_dict!(ssty_data)
    return __upget_coverage_table_dict!(
        ssty_data, ssty_data.buffer, ssty_data.lookup_tables, ssty_data.lookup_subtable_dict, ssty_data.coverage_table_dict)
end
__upget_coverage_table_dict!(ssty_data, buffer, lookup_tables, lookup_subtable_dict, coverage_table_dict)=coverage_table_dict
function __upget_coverage_table_dict!(
    ssty_data, buffer::IOBuffer, lookup_tables::Vector, lookup_subtable_dict::Dict, coverage_table_dict::Nothing)
    coverage_table_dict = ssty_data.coverage_table_dict = Dict{LOOKUP_SUB_TABLE, Union{Nothing, COVERAGE_TABLE}}()
    
    for lt in lookup_tables
        for st in lookup_subtable_dict[lt]
            isnothing(st) && continue
            coverage_table_dict[st] = CoverageTable(buffer, st)
        end
    end
    return coverage_table_dict
end

function __loopsubs_glyph_id(
    buffer, lookup_tables, lookup_subtable_dict, coverage_table_dict, glyph_id, subscript_level
)
    return glyph_id
end

function __loopsubs_glyph_id(
    buffer::IOBuffer, lookup_tables::Vector, lookup_subtable_dict::Dict, coverage_table_dict::Dict, glyph_id, subscript_level
)
    isempty(lookup_tables) && return glyph_id
    alt_glyph_id = glyph_id
    for lt in lookup_tables
        for st in lookup_subtable_dict[lt]
            isnothing(st) && continue
            coverage_table = coverage_table_dict[st]
            isnothing(coverage_table) && continue
            _nid = _subs_glyph_index(buffer, st, coverage_table, alt_glyph_id, subscript_level; default=nothing)
            if !isnothing(_nid)
                alt_glyph_id = _nid
                break
            end
        end
    end
    return alt_glyph_id
end