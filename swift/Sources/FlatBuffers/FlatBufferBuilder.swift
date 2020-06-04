import Foundation

public struct FlatBufferBuilder {
    
    /// Storage for the Vtables used in the buffer are stored in here, so they would be written later in EndTable
    @usableFromInline internal var _vtableStorage = VTableStorage()
    
    /// Reference Vtables that were already written to the buffer
    private var _vtables: [UOffset] = []
    /// Flatbuffer data will be written into
    private var _bb: ByteBuffer
    /// A check if the buffer is being written into by a different table
    private var isNested = false
    /// Dictonary that stores a map of all the strings that were written to the buffer
    private var stringOffsetMap: [String: Offset<String>] = [:]
    /// A check to see if finish(::) was ever called to retreive data object
    private var finished = false
    /// A check to see if the buffer should serialize Default values
    private var serializeDefaults: Bool
    
    /// Current alignment for the buffer
    var _minAlignment: Int = 0 {
        didSet {
            _bb.alignment = _minAlignment
        }
    }
    
    /// Gives a read access to the buffer's size
    public var size: UOffset { return _bb.size }
    /// Data representation of the buffer
    public var data: Data {
        assert(finished, "Data shouldn't be called before finish()")
        return Data(bytes: _bb.memory.advanced(by: _bb.writerIndex),
                    count: _bb.capacity - _bb.writerIndex)
    }
    /// Get's the fully sized buffer stored in memory
    public var fullSizedByteArray: [UInt8] {
        let ptr = UnsafeBufferPointer(start: _bb.memory.assumingMemoryBound(to: UInt8.self),
                                      count: _bb.capacity)
        return Array(ptr)
    }
    /// Returns the written size of the buffer
    public var sizedByteArray: [UInt8] {
        let cp = _bb.capacity - _bb.writerIndex
        let start = _bb.memory.advanced(by: _bb.writerIndex)
            .bindMemory(to: UInt8.self, capacity: cp)
        
        let ptr = UnsafeBufferPointer(start: start, count: cp)
        return Array(ptr)
    }
    /// Returns the buffer
    public var buffer: ByteBuffer { return _bb }
    
    /// Returns A sized Buffer from the readable bytes
    public var sizedBuffer: ByteBuffer {
        assert(finished, "Data shouldn't be called before finish()")
        return ByteBuffer(memory: _bb.memory.advanced(by: _bb.reader), count: Int(_bb.size))
    }
    
    // MARK: - Init
    
    /// initialize the buffer with a size
    /// - Parameters:
    ///   - initialSize: Initial size for the buffer
    ///   - force: Allows default to be serialized into the buffer
    public init(initialSize: Int32 = 1024, serializeDefaults force: Bool = false) {
        assert(initialSize > 0, "Size should be greater than zero!")
        guard isLitteEndian else {
            fatalError("Reading/Writing a buffer in big endian machine is not supported on swift")
        }
        serializeDefaults = force
        _bb = ByteBuffer(initialSize: Int(initialSize))
    }
    
    /// Clears the buffer and the builder from it's data
    mutating public func clear() {
        _minAlignment = 0
        isNested = false
        stringOffsetMap = [:]
        _vtables = []
        _vtableStorage.clear()
        _bb.clear()
    }

    // MARK: - Create Tables
    
    /// Checks if the required fields were serialized into the buffer
    /// - Parameters:
    ///   - table: offset for the table
    ///   - fields: Array of all the important fields to be serialized
    mutating public func require(table: Offset<UOffset>, fields: [Int32]) {
        for field in fields {
            let start = _bb.capacity - Int(table.o)
            let startTable = start - Int(_bb.read(def: Int32.self, position: start))
            let isOkay = _bb.read(def: VOffset.self, position: startTable + Int(field)) != 0
            assert(isOkay, "Flatbuffers requires the following field")
        }
    }
    
    /// Finished the buffer by adding the file id and then calling finish
    /// - Parameters:
    ///   - offset: Offset of the table
    ///   - fileId: Takes the fileId
    ///   - prefix: if false it wont add the size of the buffer
    mutating public func finish<T>(offset: Offset<T>, fileId: String, addPrefix prefix: Bool = false) {
        let size = MemoryLayout<UOffset>.size
        preAlign(len: size + (prefix ? size : 0) + FileIdLength, alignment: _minAlignment)
        assert(fileId.count == FileIdLength, "Flatbuffers requires file id to be 4")
        _bb.push(string: fileId, len: 4)
        finish(offset: offset, addPrefix: prefix)
    }
    
    /// Finished the buffer by adding the file id, offset, and prefix to it.
    /// - Parameters:
    ///   - offset: Offset of the table
    ///   - prefix: if false it wont add the size of the buffer
    mutating public func finish<T>(offset: Offset<T>, addPrefix prefix: Bool = false) {
        notNested()
        let size = MemoryLayout<UOffset>.size
        preAlign(len: size + (prefix ? size : 0), alignment: _minAlignment)
        push(element: refer(to: offset.o))
        if prefix { push(element: _bb.size) }
        _vtableStorage.clear()
        finished = true
    }
    
    /// starttable will let the builder know, that a new object is being serialized.
    ///
    /// The function will fatalerror if called while there is another object being serialized
    /// - Parameter numOfFields: Number of elements to be written to the buffer
    mutating public func startTable(with numOfFields: Int) -> UOffset {
        notNested()
        isNested = true
        _vtableStorage.start(count: numOfFields)
        return _bb.size
    }
    
    
    /// Endtable will let the builder know that the object that's written to it is completed
    ///
    /// This would be called after all the elements are serialized, it will add the vtable into the buffer.
    /// it will fatalError in case the object is called without starttable, or the object has exceeded  the limit of
    ///  2GB,
    /// - Parameter startOffset:Start point of the object written
    /// - returns: The root of the table
    mutating public func endTable(at startOffset: UOffset)  -> UOffset {
        assert(isNested, "Calling endtable without calling starttable")
        let sizeofVoffset = MemoryLayout<VOffset>.size
        let vTableOffset = push(element: SOffset(0))
        
        let tableObjectSize = vTableOffset - startOffset
        assert(tableObjectSize < 0x10000, "Buffer can't grow beyond 2 Gigabytes")
        let _max = UInt32(_vtableStorage.maxOffset) + UInt32(sizeofVoffset)
        
        _bb.fill(padding: _max)
        _bb.write(value: VOffset(tableObjectSize), index: _bb.writerIndex + sizeofVoffset, direct: true)
        _bb.write(value: VOffset(_max), index: _bb.writerIndex, direct: true)
        
        for index in stride(from: 0, to: _vtableStorage.writtenIndex, by: _vtableStorage.size) {
            let loaded = _vtableStorage.load(at: index)
            guard loaded.offset != 0 else { continue }
            let _index = (_bb.writerIndex + Int(loaded.position))
            _bb.write(value: VOffset(vTableOffset - loaded.offset), index: _index, direct: true)
        }
        
        _vtableStorage.clear()
        let vt_use = _bb.size
        
        var isAlreadyAdded: Int?
        
        let vt2 = _bb.memory.advanced(by: _bb.writerIndex)
        let len2 = vt2.load(fromByteOffset: 0, as: Int16.self)

        for table in _vtables {
            let position = _bb.capacity - Int(table)
            let vt1 = _bb.memory.advanced(by: position)
            let len1 = _bb.read(def: Int16.self, position: position)
            if (len2 != len1 || 0 != memcmp(vt1, vt2, Int(len2))) { continue }
            
            isAlreadyAdded = Int(table)
            break
        }
        
        if let offset = isAlreadyAdded {
            let vTableOff = Int(vTableOffset)
            let space = _bb.capacity - vTableOff
            _bb.write(value: Int32(offset - vTableOff), index: space, direct: true)
            _bb.resize(_bb.capacity - space)
        } else {
            _bb.write(value: Int32(vt_use) - Int32(vTableOffset), index: Int(vTableOffset))
            _vtables.append(_bb.size)
        }
        isNested = false
        return vTableOffset
    }
    
    // MARK: - Builds Buffer
    
    /// asserts to see if the object is not nested
    @usableFromInline mutating internal func notNested()  {
        assert(!isNested, "Object serialization must not be nested")
    }
    
    /// Changes the minimuim alignment of the buffer
    /// - Parameter size: size of the current alignment
    @usableFromInline mutating internal func minAlignment(size: Int) {
        if size > _minAlignment {
            _minAlignment = size
        }
    }
    
    /// Gets the padding for the current element
    /// - Parameters:
    ///   - bufSize: Current size of the buffer + the offset of the object to be written
    ///   - elementSize: Element size
    @usableFromInline mutating internal func padding(bufSize: UInt32, elementSize: UInt32) -> UInt32 {
        ((~bufSize) &+ 1) & (elementSize - 1)
    }
    
    /// Prealigns the buffer before writting a new object into the buffer
    /// - Parameters:
    ///   - len:Length of the object
    ///   - alignment: Alignment type
    @usableFromInline mutating internal func preAlign(len: Int, alignment: Int) {
        minAlignment(size: alignment)
        _bb.fill(padding: padding(bufSize: _bb.size + UOffset(len), elementSize: UOffset(alignment)))
    }
    
    /// Prealigns the buffer before writting a new object into the buffer
    /// - Parameters:
    ///   - len: Length of the object
    ///   - type: Type of the object to be written
    @usableFromInline mutating internal func preAlign<T: Scalar>(len: Int, type: T.Type) {
        preAlign(len: len, alignment: MemoryLayout<T>.size)
    }
    
    /// Refers to an object that's written in the buffer
    /// - Parameter off: the objects index value
    @usableFromInline mutating internal func refer(to off: UOffset) -> UOffset {
        let size = MemoryLayout<UOffset>.size
        preAlign(len: size, alignment: size)
        return _bb.size - off + UInt32(size)
    }
    
    /// Tracks the elements written into the buffer
    /// - Parameters:
    ///   - offset: The offset of the element witten
    ///   - position: The position of the element
    @usableFromInline mutating internal func track(offset: UOffset, at position: VOffset) {
        _vtableStorage.add(loc: FieldLoc(offset: offset, position: position))
    }

    // MARK: - Vectors
    
    /// Starts a vector of length and Element size
    mutating public func startVector(_ len: Int, elementSize: Int) {
        notNested()
        isNested = true
        preAlign(len: len * elementSize, type: UOffset.self)
        preAlign(len: len * elementSize, alignment: elementSize)
    }
    
    /// Ends the vector of at length
    ///
    /// The current function will fatalError if startVector is called before serializing the vector
    /// - Parameter len: Length of the buffer
    mutating public func endVector(len: Int) -> UOffset {
        assert(isNested, "Calling endVector without calling startVector")
        isNested = false
        return push(element: Int32(len))
    }
    
    /// Creates a vector of type Scalar in the buffer
    /// - Parameter elements: elements to be written into the buffer
    /// - returns: Offset of the vector
    mutating public func createVector<T: Scalar>(_ elements: [T]) -> Offset<UOffset> {
        return createVector(elements, size: elements.count)
    }
    
    ///  Creates a vector of type Scalar in the buffer
    /// - Parameter elements: Elements to be written into the buffer
    /// - Parameter size: Count of elements
    /// - returns: Offset of the vector
    mutating public func createVector<T: Scalar>(_ elements: [T], size: Int) -> Offset<UOffset> {
        let size = size
        startVector(size, elementSize: MemoryLayout<T>.size)
        _bb.push(elements: elements)
        return Offset(offset: endVector(len: size))
    }
    
    /// Creates a vector of type Enums in the buffer
    /// - Parameter elements: elements to be written into the buffer
    /// - returns: Offset of the vector
    mutating public func createVector<T: Enum>(_ elements: [T]) -> Offset<UOffset> {
        return createVector(elements, size: elements.count)
    }
    
    ///  Creates a vector of type Enums in the buffer
    /// - Parameter elements: Elements to be written into the buffer
    /// - Parameter size: Count of elements
    /// - returns: Offset of the vector
    mutating public func createVector<T: Enum>(_ elements: [T], size: Int) -> Offset<UOffset> {
        let size = size
        startVector(size, elementSize: T.byteSize)
        for e in elements.lazy.reversed() {
            _bb.push(value: e.value, len: T.byteSize)
        }
        return Offset(offset: endVector(len: size))
    }
    
    /// Creates a vector of type Offsets  in the buffer
    /// - Parameter offsets:Array of offsets of type T
    /// - returns: Offset of the vector
    mutating public func createVector<T>(ofOffsets offsets: [Offset<T>]) -> Offset<UOffset> {
        createVector(ofOffsets: offsets, len: offsets.count)
    }
    
    ///  Creates a vector of type Offsets  in the buffer
    /// - Parameter elements: Array of offsets of type T
    /// - Parameter size: Count of elements
    /// - returns: Offset of the vector
    mutating public func createVector<T>(ofOffsets offsets: [Offset<T>], len: Int) -> Offset<UOffset> {
        startVector(len, elementSize: MemoryLayout<Offset<T>>.size)
        for o in offsets.lazy.reversed() {
            push(element: o)
        }
        return Offset(offset: endVector(len: len))
    }
    
    /// Creates a vector of Strings
    /// - Parameter str: a vector of strings that will be written into the buffer
    /// - returns: Offset of the vector
    mutating public func createVector(ofStrings str: [String]) -> Offset<UOffset> {
        var offsets: [Offset<String>] = []
        for s in str {
            offsets.append(create(string: s))
        }
        return createVector(ofOffsets: offsets)
    }
    
    /// Creates a vector of Flatbuffer structs.
    ///
    /// The function takes a Type to know what size it is, and alignment
    /// - Parameters:
    ///   - structs: An array of UnsafeMutableRawPointer
    ///   - type: Type of the struct being written
    /// - returns: Offset of the vector
    mutating public func createVector<T: Readable>(structs: [UnsafeMutableRawPointer],
                                          type: T.Type) -> Offset<UOffset> {
        startVector(structs.count * T.size, elementSize: T.alignment)
        for i in structs.lazy.reversed() {
            create(struct: i, type: T.self)
        }
        return Offset(offset: endVector(len: structs.count))
    }

    // MARK: - Inserting Structs
    
    /// Writes a Flatbuffer struct into the buffer
    /// - Parameters:
    ///   - s: Flatbuffer struct
    ///   - type: Type of the element to be serialized
    /// - returns: Offset of the Object
    @discardableResult
    mutating public func create<T: Readable>(struct s: UnsafeMutableRawPointer,
                                    type: T.Type) -> Offset<UOffset> {
        let size = T.size
        preAlign(len: size, alignment: T.alignment)
        _bb.push(struct: s, size: size)
        return Offset(offset: _bb.size)
    }
    
    /// Adds the offset of a struct into the vTable
    ///
    /// The function fatalErrors if we pass an offset that is out of range
    /// - Parameter o: offset
    mutating public func add(structOffset o: VOffset) {
        _vtableStorage.add(loc: FieldLoc(offset: _bb.size, position: VOffset(o)))
    }
    
    // MARK: - Inserting Strings
    
    /// Insets a string into the buffer using UTF8
    /// - Parameter str: String to be serialized
    /// - returns: The strings offset in the buffer
    mutating public func create(string str: String) -> Offset<String> {
        let len = str.utf8.count
        notNested()
        preAlign(len: len + 1, type: UOffset.self)
        _bb.fill(padding: 1)
        _bb.push(string: str, len: len)
        push(element: UOffset(len))
        return Offset(offset: _bb.size)
    }
    
    /// Inserts a shared string to the buffer
    ///
    /// The function checks the stringOffsetmap if it's seen a similar string before
    /// - Parameter str: String to be serialized
    /// - returns: The strings offset in the buffer
    mutating public func createShared(string str: String) -> Offset<String> {
        if let offset = stringOffsetMap[str] {
            return offset
        }
        let offset = create(string: str)
        stringOffsetMap[str] = offset
        return offset
    }
    
    // MARK: - Inseting offsets
    
    /// Adds the offset of an object into the buffer
    /// - Parameters:
    ///   - offset: Offset of another object to be written
    ///   - position: The  predefined position of the object
    mutating public func add<T>(offset: Offset<T>, at position: VOffset) {
        if offset.isEmpty {
            track(offset: 0, at: position)
            return
        }
        add(element: refer(to: offset.o), def: 0, at: position)
    }
    
    /// Pushes a value of type offset into the buffer
    /// - Parameter o: Offset
    /// - returns: Position of the offset
    @discardableResult
    mutating public func push<T>(element o: Offset<T>) -> UOffset {
        push(element: refer(to: o.o))
    }
    
    // MARK: - Inserting Scalars to Buffer
    
    /// Adds a value into the buffer of type Scalar
    ///
    /// - Parameters:
    ///   - element: Element to insert
    ///   - def: Default value for that element
    ///   - position: The predefined position of the element
    mutating public func add<T: Scalar>(element: T, def: T, at position: VOffset) {
        if (element == def && !serializeDefaults) {
            track(offset: 0, at: position)
            return
        }
        let off = push(element: element)
        track(offset: off, at: position)
    }
    
    /// Adds Boolean values into the buffer
    /// - Parameters:
    ///   - condition: Condition to insert
    ///   - def: Default condition
    ///   - position: The predefined position of the element
    @available(*, deprecated, message: "Deprecated, function will be removed in Flatbuffers v0.6.0. Regenerate code")
    mutating public func add(condition: Bool, def: Bool, at position: VOffset) {
        if (condition == def && !serializeDefaults) {
            track(offset: 0, at: position)
            return
        }
        let off = push(element: Byte(condition ? 1 : 0))
        track(offset: off, at: position)
    }
    
    /// Pushes the values into the buffer
    /// - Parameter element: Element to insert
    /// - returns: Postion of the Element
    @discardableResult
    mutating public func push<T: Scalar>(element: T) -> UOffset {
        preAlign(len: MemoryLayout<T>.size,
                 alignment: MemoryLayout<T>.size)
        _bb.push(value: element, len: MemoryLayout<T>.size)
        return _bb.size
    }
    
}

extension FlatBufferBuilder: CustomDebugStringConvertible {
    
    public var debugDescription: String {
        """
        buffer debug:
        \(_bb)
        builder debug:
        { finished: \(finished), serializeDefaults: \(serializeDefaults), isNested: \(isNested) }
        """
    }

    /// VTableStorage is a class to contain the VTable buffer that would be serialized into buffer
    @usableFromInline internal class VTableStorage {
        /// Memory check since deallocating each time we want to clear would be expensive
        /// and memory leaks would happen if we dont deallocate the first allocated memory.
        /// memory is promised to be available before adding `FieldLoc`
        private var memoryInUse = false
        /// Size of FieldLoc in memory
        let size = MemoryLayout<FieldLoc>.stride
        /// Memeory buffer
        var memory: UnsafeMutableRawBufferPointer!
        /// Capacity of the current buffer
        var capacity: Int = 0
        /// Maximuim offset written to the class
        var maxOffset: VOffset = 0
        /// number of fields written into the buffer
        var numOfFields: Int = 0
        /// Last written Index
        var writtenIndex: Int = 0
        /// the amount of added elements into the buffer
        var addedElements: Int { return capacity - (numOfFields * size) }
        
        /// Creates the memory to store the buffer in
        init() {
            memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 0, alignment: 0)
        }
        
        deinit {
            memory.deallocate()
        }
        
        /// Builds a buffer with byte count of fieldloc.size * count of field numbers
        /// - Parameter count: number of fields to be written
        func start(count: Int) {
            let capacity = count * size
            ensure(space: capacity)
        }
        
        /// Adds a FieldLoc into the buffer, which would track how many have been written,
        /// and max offset
        /// - Parameter loc: Location of encoded element
        func add(loc: FieldLoc) {
            memory.baseAddress?.advanced(by: writtenIndex).storeBytes(of: loc, as: FieldLoc.self)
            writtenIndex += size
            numOfFields += 1
            maxOffset = max(loc.position, maxOffset)
        }
        
        /// Clears the data stored related to the encoded buffer
        func clear() {
            maxOffset = 0
            numOfFields = 0
            writtenIndex = 0
        }
        
        /// Ensure that the buffer has enough space instead of recreating the buffer each time.
        /// - Parameter space: space required for the new vtable
        func ensure(space: Int) {
            guard space + writtenIndex > capacity else { return }
            memory.deallocate()
            memory = UnsafeMutableRawBufferPointer.allocate(byteCount: space, alignment: size)
            capacity = space
        }

        /// Loads an object of type `FieldLoc` from buffer memory
        /// - Parameter index: index of element
        /// - Returns: a FieldLoc at index
        func load(at index: Int) -> FieldLoc {
            return memory.load(fromByteOffset: index, as: FieldLoc.self)
        }
        
    }
    
    internal struct FieldLoc {
        var offset: UOffset
        var position: VOffset
    }

}
