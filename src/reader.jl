import Zlib_jll

function unsafe_crc32(p::Ptr{UInt8}, nb::UInt, crc::UInt32)::UInt32
    ccall((:crc32_z, Zlib_jll.libz),
        Culong, (Culong, Ptr{UInt8}, Csize_t),
        crc, p, nb,
    )
end

function zip_crc32(data::DenseVector{UInt8}, crc::UInt32=UInt32(0))::UInt32
    GC.@preserve data unsafe_crc32(pointer(data), UInt(length(data)), crc)
end

function zip_crc32(data::AbstractVector{UInt8}, crc::UInt32=UInt32(0))::UInt32
    zip_crc32(collect(data), crc)
end

# Copied from ZipFile.jl
readle(io::IO, ::Type{UInt64}) = htol(read(io, UInt64))
readle(io::IO, ::Type{UInt32}) = htol(read(io, UInt32))
readle(io::IO, ::Type{UInt16}) = htol(read(io, UInt16))
readle(io::IO, ::Type{UInt8}) = read(io, UInt8)


function Base.:(==)(x::EntryInfo, y::EntryInfo)
    iox = IOBuffer()
    write_central_header(iox, x)
    ioy = IOBuffer()
    write_central_header(ioy, y)
    take!(iox) == take!(ioy)
end


need_zip64(entry::EntryInfo)::Bool = (
    entry.u_size_zip64 ||
    entry.c_size_zip64 ||
    entry.offset_zip64 ||
    entry.n_disk_zip64
)

"""
Return the size of a typical local header for an entry.
Note, zip files in the wild may have shorter 
or longer local headers if they have a different 
amount of local extra fields.
"""
normal_local_header_size(entry::EntryInfo) = 50 + ncodeunits(entry.name)

"""
Return the minimum size of a local header for an entry.
"""
min_local_header_size(entry::EntryInfo) = 30 + ncodeunits(entry.name)

const HasEntries = Union{ZipFileReader,ZipWriter,ZipBufferReader}

zip_nentries(x::HasEntries) = length(x.entries)
zip_entryname(x::HasEntries, i) = x.entries[i].name




# If this fails, io isn't a zip file, io isn't seekable, 
# or the end of the zip file was corrupted
function find_end_of_central_directory_record(io::IO)::Int64
    seekend(io)
    fsize = position(io)
    # First assume comment is length zero
    fsize ≥ 22 || throw(ArgumentError("io isn't a zip file. Too small"))
    seek(io, fsize-22)
    b = read!(io, zeros(UInt8, 22))
    check_comment_len_valid(b, comment_len) = (
        EOCDSig == @view(b[end-21-comment_len:end-18-comment_len]) &&
        comment_len%UInt8 == b[end-1-comment_len] &&
        UInt8(comment_len>>8) == b[end-comment_len]
    )
    if check_comment_len_valid(b, 0)
        # No Zip comment fast path
        fsize-22
    else
        # There maybe is a Zip comment slow path
        fsize > 22 || throw(ArgumentError("io isn't a zip file."))
        max_comment_len::Int = min(0xFFFF, fsize-22)
        seek(io, fsize - (max_comment_len+22))
        b = read!(io, zeros(UInt8, (max_comment_len+22)))
        comment_len = 1
        while comment_len < max_comment_len && !check_comment_len_valid(b, comment_len)
            comment_len += 1
        end
        if !check_comment_len_valid(b, comment_len)
            throw(ArgumentError("""
                io isn't a zip file. 
                It may be a zip file with a corrupted ending.
                """
            ))
        end
        fsize-22-comment_len
    end
end

function check_EOCD64_used(io::IO, eocd_offset)::Bool
    # Verify that ZIP64 end of central directory is used
    # It may be that one of the values just happens to be -1
    eocd_offset ≥ 56+20 || return false
    seek(io, eocd_offset - 20)
    readle(io, UInt32) == 0x07064b50 || return false
    skip(io, 4)
    maybe_eocd64_offset = readle(io, UInt64)
    readle(io, UInt32) ≤ 1 || return false # total number of disks
    maybe_eocd64_offset ≤ eocd_offset - (56+20) || return false
    seek(io, maybe_eocd64_offset)
    readle(io, UInt32) == 0x06064b50 || return false
    return true
end

"""
    parse_central_directory(io::IO)::Tuple{Vector{EntryInfo}, Int64}

Where `io` must be readable and seekable.
`io` is assumed to not be changed while this function runs.

Return the entries, and the offset in `io` of the start of the central directory as a named tuple. `(;entries, central_dir_offset)`

The central directory is after all file data.

"""
function parse_central_directory(io::IO)
    # 1st find end of central dir section
    eocd_offset::Int64 = find_end_of_central_directory_record(io)
    # 2nd find where the central dir is and 
    # how many entries there are.
    # This is confusing because of ZIP64 and disk number weirdness.
    seek(io, eocd_offset+4)
    # number of this disk, or -1
    disk16 = readle(io, UInt16)
    # number of the disk with the start of the central directory or -1
    cd_disk16 = readle(io, UInt16)
    # Only one disk with num 0 is supported.
    if disk16 != -1%UInt16
        @argcheck disk16 == 0
    end
    if cd_disk16 != -1%UInt16
        @argcheck cd_disk16 == 0
    end
    # total number of entries in the central directory on this disk or -1
    num_entries_thisdisk16 = readle(io, UInt16)
    # total number of entries in the central directory or -1
    num_entries16 = readle(io, UInt16)
    # size of the central directory or -1
    skip(io, 4)
    # offset of start of central directory with respect to the starting disk number or -1
    central_dir_offset32 = readle(io, UInt32)
    maybe_eocd64 = (
        any( ==(-1%UInt16), [
            disk16,
            cd_disk16,
            num_entries_thisdisk16,
            num_entries16,
        ]) ||
        central_dir_offset32 == -1%UInt32
    )
    use_eocd64 = maybe_eocd64 && check_EOCD64_used(io, eocd_offset)
    central_dir_offset::Int64, num_entries::Int64 = let 
        if use_eocd64
            # Parse Zip64 end of central directory record
            # Error if not valid
            seek(io, eocd_offset - 20)
            # zip64 end of central dir locator signature
            @argcheck readle(io, UInt32) == 0x07064b50
            # number of the disk with the start of the zip64 end of central directory
            # Only one disk with num 0 is supported.
            @argcheck readle(io, UInt32) == 0
            local eocd64_offset = readle(io, UInt64)
            local total_num_disks = readle(io, UInt32)
            @argcheck total_num_disks ≤ 1
            seek(io, eocd64_offset)
            # zip64 end of central dir signature
            @argcheck readle(io, UInt32) == 0x06064b50
            # size of zip64 end of central directory record
            skip(io, 8)
            # version made by
            skip(io, 2)
            # version needed to extract
            # This is set to 62 if version 2 of ZIP64 is used
            # This is not supported yet.
            local version_needed = readle(io, UInt16)
            @argcheck version_needed < 62
            # number of this disk
            @argcheck readle(io, UInt32) == 0
            # number of the disk with the start of the central directory
            @argcheck readle(io, UInt32) == 0
            # total number of entries in the central directory on this disk
            local num_entries_thisdisk64 = readle(io, UInt64)
            # total number of entries in the central directory
            local num_entries64 = readle(io, UInt64)
            @argcheck num_entries64 == num_entries_thisdisk64
            if num_entries16 != -1%UInt16
                @argcheck num_entries64 == num_entries16
            end
            if num_entries_thisdisk16 != -1%UInt16
                @argcheck num_entries64 == num_entries_thisdisk16
            end
            # size of the central directory
            skip(io, 8)
            # offset of start of central directory with respect to the starting disk number
            local central_dir_offset64 = readle(io, UInt64)
            if central_dir_offset32 != -1%UInt32
                @argcheck central_dir_offset64 == central_dir_offset32
            end
            @argcheck central_dir_offset64 ≤ eocd64_offset
            (Int64(central_dir_offset64), Int64(num_entries64))
        else
            @argcheck disk16 == 0
            @argcheck cd_disk16 == 0
            @argcheck num_entries16 == num_entries_thisdisk16
            @argcheck central_dir_offset32 ≤ eocd_offset
            (Int64(central_dir_offset32), Int64(num_entries16))
        end
    end
    seek(io, central_dir_offset)
    # parse central directory headers
    entries = EntryInfo[]
    for i in 1:num_entries
        local entry = EntryInfo(;name="", offset=0)
        # central file header signature
        @argcheck readle(io, UInt32) == 0x02014b50
        entry.version_made = readle(io, UInt8)
        entry.os = readle(io, UInt8)
        entry.version_needed = readle(io, UInt16)
        entry.bit_flags = readle(io, UInt16)
        entry.method = readle(io, UInt16)
        entry.dos_time = readle(io, UInt16)
        entry.dos_date = readle(io, UInt16)
        entry.crc32 = readle(io, UInt32)
        local c_size32 = readle(io, UInt32)
        local u_size32 = readle(io, UInt32)
        local name_len = readle(io, UInt16)
        local extras_len = readle(io, UInt16)
        local comment_len = readle(io, UInt16)
        local disk16 = readle(io, UInt16)
        entry.internal_attrs = readle(io, UInt16)
        entry.external_attrs = readle(io, UInt32)
        local offset32 = readle(io, UInt32)

        entry.name = String(read(io, name_len))
        @argcheck ncodeunits(entry.name) == name_len

        #reading the variable sized extra fields
        local central_extras = entry.central_extras
        local extras_bytes_left::Int = extras_len
        while extras_bytes_left ≥ 4
            local id = readle(io, UInt16)
            local data_size = readle(io, UInt16)
            extras_bytes_left -= 4
            @argcheck data_size ≤ extras_bytes_left
            local data = read(io, data_size)
            @argcheck length(data) == data_size
            extras_bytes_left -= data_size
            push!(central_extras, ExtraField(id, data))
        end
        @argcheck iszero(extras_bytes_left)

        if !iszero(comment_len)
            entry.comment = String(read(io, comment_len))
            @argcheck ncodeunits(entry.comment) == comment_len
        end

        # Parse Zip64 and check disk number is 0
        # Assume no zip64 is used, unless the extra field is found
        entry.uncompressed_size = u_size32
        entry.compressed_size = c_size32
        entry.offset = offset32
        local n_disk::UInt32 = disk16
        entry.c_size_zip64 = false
        entry.u_size_zip64 = false
        entry.offset_zip64 = false
        entry.n_disk_zip64 = false
        local zip64_idx = findfirst(x->(x.id==0x0001), central_extras)
        if !isnothing(zip64_idx) && entry.version_needed ≥ 45
            local zip64_data = central_extras[zip64_idx].data
            local b = IOBuffer(zip64_data)
            if u_size32 == -1%UInt32 && bytesavailable(b) ≥ 8
                entry.uncompressed_size = readle(b, UInt64)
                entry.u_size_zip64 = true
            end
            if c_size32 == -1%UInt32 && bytesavailable(b) ≥ 8
                entry.compressed_size = readle(b, UInt64)
                entry.c_size_zip64 = true
            end
            if offset32 == -1%UInt32 && bytesavailable(b) ≥ 8
                entry.offset = readle(b, UInt64)
                entry.offset_zip64 = true
            end
            if disk16 == -1%UInt16 && bytesavailable(b) ≥ 4
                n_disk = readle(b, UInt32)
                entry.n_disk_zip64 = true
            end
        end
        @argcheck n_disk == 0
        push!(entries, entry)
    end
    # Maybe num_entries was too small: See https://github.com/thejoshwolfe/yauzl/issues/60
    # In that case just log a warning
    if readle(io, UInt32) == 0x02014b50
        @warn "There may be some entries that are being ignored"
    end

    (;entries, central_dir_offset)
end

function ZipFileReader(filename::AbstractString)
    io = open(filename; lock=false)
    try # parse entries
        entries, central_dir_offset = parse_central_directory(io)
        ZipFileReader(
            entries,
            central_dir_offset,
            io,
            Ref(1),
            Ref(true),
            ReentrantLock(),
            filesize(io),
        )
    catch # close io if there is an error parsing entries
        close(io)
        rethrow()
    end
end

function ZipFileReader(f::Function, filename::AbstractString; kwargs...)
    r = ZipFileReader(filename; kwargs...)
    try
        f(r)
    finally
        close(r)
    end
end

Base.isopen(r::ZipFileReader)::Bool = r._open[]

"""
Throw an ArgumentError if entry cannot be extracted.
"""
function validate_entry(entry::EntryInfo, fsize::Int64)
    if entry.method != Store && entry.method != Deflate
        throw(ArgumentError("invalid compression method. Only Store and Deflate supported for now"))
    end
    # Check for unsupported bit flags
    @argcheck iszero(entry.bit_flags & 1<<0) "encrypted files not supported"
    @argcheck iszero(entry.bit_flags & 1<<5) "patched data not supported"
    @argcheck iszero(entry.bit_flags & 1<<6) "encrypted files not supported"
    @argcheck iszero(entry.bit_flags & 1<<13) "encrypted files not supported"
    @argcheck entry.version_needed ≤ 45
    # This allows for files to overlap, which sometimes can happen.
    @argcheck entry.compressed_size ≤ fsize - min_local_header_size(entry)
    if entry.method == Store
        @argcheck entry.compressed_size == entry.uncompressed_size
    end
    @argcheck entry.offset ≤ (fsize - min_local_header_size(entry)) - entry.compressed_size
    nothing
end


"""
    zip_openentry(r::ZipFileReader, i::Integer)

Open entry `i` from `r` as a readable IO.

Make sure to close this when done reading.

Multiple entries can be open and read at the same time in multiple threads.
The stream returned by this function should not be 
read concurrently.
"""
function zip_openentry(r::ZipFileReader, i::Integer)::TranscodingStream
    entry::EntryInfo = r.entries[i]
    validate_entry(entry, r._fsize)
    lock(r._lock) do
        if r._open[]
            @assert r._ref_counter[] > 0 
            r._ref_counter[] += 1
        else
            throw(ArgumentError("ZipFileReader is closed"))
        end
    end
    offset::Int64 = entry.offset
    method = entry.method
    lock(r._lock) do
        # read and validate local header
        seek(r._io, offset)
        @argcheck readle(r._io, UInt32) == 0x04034b50
        skip(r._io, 4)
        @argcheck readle(r._io, UInt16) == method
        skip(r._io, 4*4)
        local_name_len = readle(r._io, UInt16)
        @argcheck local_name_len == ncodeunits(entry.name)
        extra_len = readle(r._io, UInt16)
        @argcheck String(read(r._io, local_name_len)) == entry.name
        skip(r._io, extra_len)
        offset += 30 + extra_len + local_name_len
        @argcheck offset + entry.compressed_size ≤ r._fsize
    end
    base_io = ZipFileEntryReader(
        r,
        0,
        -1,
        offset,
        entry.crc32,
        entry.compressed_size,
        Ref(true),
    )
    try
        if method == Store
            return NoopStream(base_io)
        elseif method == Deflate
            return DeflateDecompressorStream(base_io)
        else
            error("unknown compression method $method. Only Deflate and Store are supported.")
        end
    catch
        close(base_io)
        rethrow()
    end
end

function zip_openentry(f::Function, r::Union{ZipFileReader, ZipBufferReader}, args...; kwargs...)
    io = zip_openentry(r, args...; kwargs...)
    try
        f(io)
    finally
        close(io)
    end
end

# Readable IO interface for ZipFileEntryReader
Base.isopen(io::ZipFileEntryReader)::Bool = io._open[]

Base.bytesavailable(io::ZipFileEntryReader)::Int64 = io.compressed_size - io.p

Base.iswritable(io::ZipFileEntryReader)::Bool = false

Base.eof(io::ZipFileEntryReader)::Bool = iszero(bytesavailable(io))

function Base.unsafe_read(io::ZipFileEntryReader, p::Ptr{UInt8}, n::UInt)::Nothing
    @argcheck isopen(io)
    n_real::UInt = min(n, bytesavailable(io))
    r = io.r
    read_start = io.offset+io.p
    lock(r._lock) do
        seek(r._io, read_start)
        unsafe_read(r._io, p, n_real)
    end
    io.p += n_real
    if n_real != n
        @assert eof(io)
        throw(EOFError())
    end
    nothing
end

Base.position(io::ZipFileEntryReader)::Int64 = io.p

function Base.seek(io::ZipFileEntryReader, n::Integer)::ZipFileEntryReader
    @argcheck Int64(n) ∈ 0:io.compressed_size
    io.p = Int64(n)
    return io
end

function Base.seekend(io::ZipFileEntryReader)::ZipFileEntryReader
    io.p = io.compressed_size
    return io
end

# Close will only actually close the internal io
# when all ZipFileEntryReader and ZipFileReader referencing the io
# call close.
function Base.close(io::ZipFileEntryReader)::Nothing
    if isopen(io)
        io._open[] = false
        io.p = io.compressed_size
        r = io.r
        lock(r._lock) do
            @assert r._ref_counter[] > 0 
            r._ref_counter[] -= 1
            if r._ref_counter[] == 0
                @assert !r._open[]
                close(r._io)
            end
        end
    end
    nothing
end

function Base.close(r::ZipFileReader)::Nothing
    if isopen(r)
        lock(r._lock) do
            if r._open[]
                r._open[] = false
                @assert r._ref_counter[] > 0 
                r._ref_counter[] -= 1
                if r._ref_counter[] == 0
                    close(r._io)
                end
            end
        end
    end
    nothing
end

function ZipBufferReader(data::T) where T<:AbstractVector{UInt8}
    io = IOBuffer(data)
    entries, central_dir_offset = parse_central_directory(io)
    ZipBufferReader{T}(entries, central_dir_offset, data)
end

function zip_openentry(r::ZipBufferReader, i::Integer)
    entry::EntryInfo = r.entries[i]
    validate_entry(entry, length(r.buffer))
    io = IOBuffer(r.buffer)
    offset::Int64 = entry.offset
    method = entry.method
    # read and validate local header
    seek(io, offset)
    @argcheck readle(io, UInt32) == 0x04034b50
    skip(io, 4)
    @argcheck readle(io, UInt16) == method
    skip(io, 4*4)
    local_name_len = readle(io, UInt16)
    @argcheck local_name_len == ncodeunits(entry.name)
    extra_len = readle(io, UInt16)
    @argcheck String(read(io, local_name_len)) == entry.name
    skip(io, extra_len)
    offset += 30 + extra_len + local_name_len
    @argcheck offset + entry.compressed_size ≤ length(r.buffer)
    startidx = firstindex(r.buffer) + offset
    lastidx = firstindex(r.buffer) + offset + entry.compressed_size - 1
    base_io = IOBuffer(view(r.buffer, startidx:lastidx))
    if method == Store
        return base_io
    elseif method == Deflate
        return DeflateDecompressorStream(base_io)
    else
        error("unknown compression method $method. Only Deflate and Store are supported.")
    end
end