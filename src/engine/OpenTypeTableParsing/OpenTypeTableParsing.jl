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

function _get_snft_table_buffer(face::FTFont, tag::FT_TAG; throw_error::Bool=true)::Union{Nothing, IOBuffer}
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

include("ssty.jl")
include("math.jl")

end#module