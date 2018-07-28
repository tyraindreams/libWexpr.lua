--- Wexpr encoding and decoding library.
-- Allows you to serialize and deserialize the Wexp text format.
-- @module libWexpr
-- @author Alexander Clay
-- @copyright 2018
-- @license MIT/X11
local libWexpr = {
	--- Version of the library.
	version = "0.1.0",
	--- Wexpr spec currently employed by the library.
	WexprSpec = "0.1",

	--- index pointer of the chunk when tokenizing or tokenTable when parsing.
	index = 1,
	--- The chunk currently being processed for decoding.
	chunk = "",
	--- The chunk broken down into lines for error reporting.
	chunkLines = {},
	--- The token table with all syntactical tokens.
	tokenTable = {},
	--- The reference table with all reference definitions.
	references = {},
	--- An array of warning messages generated by the encode and decode functions.
	warnings = {},
	--- The last error message generated by either the encode or decode functions.
	errormsg = "",

	--- Map of chars to escape in a string.
	escapeChar = {
		["\\"] = "\\\\",
		["\r"] = "\\r",
		["\n"] = "\\n",
		["\t"] = "\\t",
		["\""] = "\\\""
	},
	--- The inverted version of escapeChar which is generated by the init function
	-- @see init
	unescapeChar = {},

	--- String of base64 characters in their position of meaning.
	base64Code = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/',

	--- List of valid tokens.
	-- @field name The readable name of the token. Used in error messages and warnings.
	-- @field pattern The function called to match the text pattern for the token. Returns a string with the token in it if found otherwise it returns nil.
	-- @field syntax True if the token is a syntactical component, false if its not and should be discarded by the tokenizer.
	-- @field getValue A function that gets the value of the token converted to something lua compatible. If nil the token has no achieveable value.
	tokens = {
		{
			name = "whitespace",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^([ \t]+)")
			end,
			syntax = false
		},
		{
			name = "newline",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^([\r\n]+)")
			end,
			syntax = false
		},
		{
			name = "block comment",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(;%(%-%-.-%-%-%))")
			end,
			syntax = false
		},
		{
			name = "comment",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^([;][^\n]*)")
			end,
			syntax = false
		},
		{
			name = "string",
			pattern = function(self, chunk, index)
				if string.sub(chunk, index, index) ~= "\"" then return nil end
				local str = "\""
				local i=index+1
				while i <= #chunk do
					local char = string.sub(chunk, i, i)
					if char == "\"" then
						return str .. "\""
					elseif char == "\\" then
						i=i+1
						if i>#chunk then break end
						str = str .. char
						char = string.sub(chunk, i, i)
						if char ~= "r" and char ~= "n" and char ~= "t" and char ~= "\"" and char ~= "\\" then
							self:throw("Syntax Error: Invalid escape sequence in string.", i-1, 2)
						end
						str = str .. char
					else
						str = str .. char
					end
					i=i+1
				end
				self:throw("Syntax Error: File ended unexpectedly inside of string.", #self.chunk)
			end,
			syntax = true,
			getValue = function(self, table)
				return self:unescapeString(string.sub(self:getToken().token, 2, -2))
			end
		},
		{
			name = "number",
			pattern = function(self, chunk, index)
				local str = ""
				local i=index
				if string.sub(chunk, i, i) == "-" then
					i=i+1
					str = "-"
				end
				num = string.match(string.sub(chunk, i), "^([%d]+[.][%d]+)")
				if num == nil then
					num = string.match(string.sub(chunk, i), "^([%d]+)")
				end
				if num == nil then return nil end
				return str .. num
			end,
			syntax = true,
			getValue = function(self, table)
				return tonumber(self:getToken().token)
			end
		},
		{
			name = "word",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^([^%<%>%*#@%(%);%[%]\r\n \t]+)")
			end,
			syntax = true,
			interpret = { -- Whether or not a word is interpretted as a valid concept in lua. The encode function uses this to determine if a string can be converted into a bare word or not.
				_true = true,
				_false = true,
				_null = true,
				_nil = true
			},
			getValue = function(self, table)
				local token = self:getToken().token
				if token == "true" then
					return true
				elseif token == "false" then
					return false
				elseif token == "nil" then
					return nil
				elseif token == "null" then
					return nil
				else
					return  token
				end
			end
		},
		{
			name = "binary",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(%<[a-zA-Z0-9%+/=]+%>)")
			end,
			syntax = true,
			getValue = function(self, table)
				return self:base64Decode(string.sub(self:getToken().token, 2, -2))
			end
		},
		{
			name = "map",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(@%()")
			end,
			syntax = true,
			getValue = function(self, table)
				table = table or {}
				return self:decodeMap(table)
			end
		},
		{
			name = "array",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(#%()")
			end,
			syntax = true,
			getValue = function(self, table)
				table = table or {}
				return self:decodeArray(table)
			end
		},
		{
			name = "reference",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(%*%[[a-zA-Z_][a-zA-Z0-9_]*%])")
			end,
			syntax = true,
			getValue = function(self, table)
				local reference = self:getToken()
				local referenceName = string.match(reference.token, "^%*%[([a-zA-Z_][a-zA-Z0-9_]*)%]")
				if self.references[referenceName] == nil then
					self:throw("Syntax Error: Reference [" .. referenceName .."] is undefined.", reference.index, #reference.token)
				end
				return self.references[referenceName].value
			end
		},
		{
			name = "reference definition",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(%[[ \t]*[a-zA-Z_][a-zA-Z0-9_]*[ \t]*%])")
			end,
			syntax = true,
			getValue = function(self, table)
				local reference = self:getToken()
				local referenceName = string.match(reference.token, "^%[[ \t]*([a-zA-Z_][a-zA-Z0-9_]*)[ \t]*%]")

				if self.references[referenceName] ~= nil then
					self:warn("Warning: Redefining previously defined reference [" .. referenceName .."].", reference.index, #reference.token)
					self:warn("Warning: Reference [" .. referenceName .."] was previously defined here.", self.references[referenceName].token.index, #self.references[referenceName].token.token)
				end

				local token = self:nextToken()
				if self.tokens[token.type].getValue == nil then
					self:throw("Syntax Error: Expected value to define reference [" .. referenceName .."] but instead found " .. self.tokens[token.type].name .. ".", token.index, #token.token)
				end

				local value = self.tokens[token.type].getValue(self, table)
				self.references[referenceName] = {
					token = reference,
					value = value
				}
				return value
			end
		},
		{
			name = "close scope",
			pattern = function(self, chunk, index)
				return string.match(string.sub(chunk, index), "^(%))")
			end,
			syntax = true
		}
	},
	--- The inverse of tokens in that it takes the readable name and converts it to the array position of the token in the tokens table. Generated by the init function.
	-- @see tokens
	-- @see init
	tokensMap = {},

	--- Initializes the library and generates some of the tables used.
	-- @tparam table self This function is called as a method.
	init = function(self)
		for i=1, #self.tokens do
			self.tokensMap[self.tokens[i].name] = i
		end
		for k,v in pairs(self.escapeChar) do
			self.unescapeChar[v] = k
		end
	end,

	--- Checks a string to make sure it UTF8 safe.
	-- @tparam table self This function is called as a method.
	-- @tparam string data The string to check.
	-- @treturn bool Return true if the string is UTF8 safe.
	isValidUTF8 = function(self, data)
		if #data == 0 then return true end
		local i = 1
		while i <= #data do
			local char = string.sub(data, i, i+3)
			if string.match(char, "^[%z\1-\127]") then
				i=i+1
			elseif string.match(char, "^[\194-\223][\128-\191]") then
				i=i+2
			elseif string.match(char, "^[\224][\160-\191][\128-\191]") then
				i=i+3
			elseif string.match(char, "^[\225-\236][\128-\191][\128-\191]") then
				i=i+3
			elseif string.match(char, "^[\237][\128-\159][\128-\191]") then
				i=i+3
			elseif string.match(char, "^[\238-\239][\128-\191][\128-\191]") then
				i=i+3
			elseif string.match(char, "^[\240][\144-\191][\128-\191][\128-\191]") then
				i=i+4
			elseif string.match(char, "^[\241-\243][\128-\191][\128-\191][\128-\191]") then
				i=i+4
			elseif string.match(char, "^[\244][\128-\143][\128-\191][\128-\191]") then
				i=i+4
			else
				return false
			end
		end
		return true
	end,

	--- Escapes all the characters in the string to be spec safe.
	-- @tparam table self This function is called as a method.
	-- @tparam string str The string to escape.
	-- @treturn string The escaped string.
	-- @see escapeChar
	escapeString = function(self, str)
		for k,v in pairs(self.escapeChar) do
			str = str:gsub(k, v)
		end
		return str
	end,

	--- Replaces all escape sequences with actual characters.
	-- @tparam table self This function is called as a method.
	-- @tparam string str The string to make spec safe.
	-- @treturn string The spec safe string.
	-- @see unescapeChar
	unescapeString = function(self, str)
		for k,v in pairs(self.unescapeChar) do
			str = str:gsub(k, v)
		end
		return str
	end,

	--- Encode a string into base64 data.
	-- @tparam table self This function is called as a method.
	-- @tparam string data The string to encode into base64.
	-- @treturn string The base64 encoded string.
	base64Encode = function (self, data)
		local b=self.base64Code
		return ((data:gsub('.', function(x) 
						local r,b='',x:byte()
						for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
						return r;
					end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
					if (#x < 6) then return '' end
					local c=0
					for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
					return b:sub(c+1,c+1)
				end)..({ '', '==', '=' })[#data%3+1])
	end,

	--- Decode a base64 string.
	-- @tparam table self This function is called as a method.
	-- @tparam string data The string to decode.
	-- @treturn string The decoded string.
	base64Decode = function (self, data)
		local b=self.base64Code
		data = string.gsub(data, '[^'..b..'=]', '')
		return (data:gsub('.', function(x)
					if (x == '=') then return '' end
					local r,f='',(b:find(x)-1)
					for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
					return r;
				end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
					if (#x ~= 8) then return '' end
					local c=0
					for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
					return string.char(c)
				end))
	end,

	--- Throw an error.
	-- This instantly terminates the decode call.
	-- @tparam table self This function is called as a method.
	-- @tparam string errormsg The error message to use for the error.
	-- @tparam number index The index position in the chunk of the error.
	-- @tparam[opt=0] number length The length of the token. Defaults to 0. Used to generate the indicator for errors.
	-- @see errormsg
	throw = function(self, errormsg, index, length)

		local line, position = self:indexToLinePosition(index)
		errormsg = line .. ":" .. position .. ":" .. errormsg ..  "\n" .. self.chunkLines[line] .. "\n" .. self:generateLinePosition(position, length)
		self.errormsg = errormsg
		error(errormsg)

	end,

	--- Generate a warning.
	-- @tparam table self This function is called as a method.
	-- @tparam string errormsg The warning message to use for the warning.
	-- @tparam number index The index position in the chunk of the warning.
	-- @tparam[opt=0] number length The length of the token. Defaults to 0. Used to generate the indicator for warning.
	-- @see warnings
	warn = function(self, errormsg, index, length)

		local line, position = self:indexToLinePosition(index)
		errormsg = line .. ":" .. position .. ":" .. errormsg ..  "\n" .. self.chunkLines[line] .. "\n" .. self:generateLinePosition(position, length)
		table.insert(self.warnings, errormsg)

	end,

	--- Generates the line position string for errors and warnings.
	-- @tparam table self This function is called as a method.
	-- @tparam number position The position the indicator starts at.
	-- @tparam number length The length of the indicator.
	-- @treturn string The line position string.
	generateLinePosition = function(self, position, length)
		length = length or 0
		local line = ""
		for i = 1, position-1 do line = line .. " " end
		line = line .. "^"
		for i = 1, length-1 do line = line .. "~" end
		return line
	end,

	--- Encode a table or value into a Wexpr.
	-- @tparam table self This function is called as a method.
	-- @tparam any Table The table or value to encode. Cannot be a function or userdata.
	-- @tparam bool pretty Whether or not to pretty print the Wexpr. Defaults to false.
	-- @tparam table binary The paths to strings to force output as binary. '-' is the base table and everything else is in standard lua . notation. An example would be {["-.table.key"] = true, ["-.table.key2"] = true} would force Table.table.key and Table.table.key2 to be output as binary if they were strings.
	-- @treturn string The Wexpr as a string.
	-- @treturn string The error message. Will equal nil if there was no error.
	encode = function(self, Table, pretty, binary)
		pretty = pretty or false
		binary = binary or {}

		self.warnings = {}
		self.errormsg = ""
		local indent = -1
		indentString = " "
		if pretty then
			indent = 0
			indentString = "\n"
		end

		local encodeCall = function()
			return self:encodeValue(indent, "-", Table, indentString, binary)
		end

		local status, result = pcall(encodeCall)
		if status then
			return result
		else
			if self.errormsg ~= "" then
				return nil, self.errormsg
			else
				return nil, result
			end
		end

	end,

	--- Encode a map.
	-- @tparam table self This function is called as a method.
	-- @tparam table Table the table to encode.
	-- @tparam string chunk The chunk to use for writing the table to.
	-- @tparam number indent The indent level to generate the preceeding indentation for.
	-- @tparam string path The current path to the table.
	-- @tparam table binary The paths to strings to force output as binary. '-' is the base table and everything else is in standard lua . notation. An example would be {["-.table.key"] = true, ["-.table.key2"] = true} would force Table.table.key and Table.table.key2 to be output as binary if they were strings.
	-- @treturn string The chunk with the map appended.
	encodeMap = function(self, Table, chunk, indent, path, binary)

		local indentString = " "
		if indent > -1 then
			indentString = "\n"
			for i=1, indent do
				indentString = indentString .. "\t"
			end
		end

		for k, v in pairs(Table) do
			local vchunk = self:encodeValue(indent, path .. "." .. k, v, indentString, binary)
			if vchunk ~= nil then
				if type(k) == "number" then
					chunk = chunk .. indentString .. tostring(k) .. " " .. vchunk
				else
					if #(self.tokens[self.tokensMap["word"]].pattern(self, k, 1)) == #k and not self.tokens[self.tokensMap["word"]].interpret["_"..k] then
						chunk = chunk .. indentString .. tostring(k) .. " " .. vchunk
					else
						if not self:isValidUTF8(k) then
							self.errormsg = path .. ":Error: Map keys can only be valid UTF-8 strings."
							error(self.errormsg)
						else
							chunk = chunk .. indentString .. "\"" .. self:escapeString(k) .. "\"" .. " " .. vchunk
						end
					end
				end
			end
		end

		return chunk

	end,
	--- Encode an array.
	-- @tparam table self This function is called as a method.
	-- @tparam table Table the table to encode.
	-- @tparam string chunk The chunk to use for writing the table to.
	-- @tparam number indent The indent level to generate the preceeding indentation for.
	-- @tparam string path The current path to the table.
	-- @tparam table binary The paths to strings to force output as binary. '-' is the base table and everything else is in standard lua . notation. An example would be {["-.table.key"] = true, ["-.table.key2"] = true} would force Table.table.key and Table.table.key2 to be output as binary if they were strings.
	-- @treturn string The chunk with the array appended.
	encodeArray = function(self, Table, chunk, indent, path, binary)

		local indentString = " "
		if indent > -1 then
			indentString = "\n"
			for i=1, indent do
				indentString = indentString .. "\t"
			end
		end

		for k, v in pairs(Table) do
			local vchunk = self:encodeValue(indent, path .. "." .. k, v, indentString, binary)
			if vchunk ~= nil then
				chunk = chunk .. indentString .. vchunk
			end
		end

		return chunk

	end,

	--- Encode a value.
	-- @tparam table self This function is called as a method.
	-- @tparam string chunk The chunk to use for writing the value to.
	-- @tparam number indent The indent level to generate the preceeding indentation for.
	-- @tparam string path The current path to the value.
	-- @tparam value v The value to encode.
	-- @tparam table binary The paths to strings to force output as binary. '-' is the base table and everything else is in standard lua . notation. An example would be {["-.table.key"] = true, ["-.table.key2"] = true} would force Table.table.key and Table.table.key2 to be output as binary if they were strings.
	-- @treturn string The chunk with the value appended.
	encodeValue = function(self, indent, path, v, indentString, binary)
		local chunk = ""
		if type(v) == "string" then
			if #(self.tokens[self.tokensMap["word"]].pattern(self, v, 1)) == #v and not self.tokens[self.tokensMap["word"]].interpret["_"..v] and not binary[path] then
				chunk = chunk .. v
			else
				if (not self:isValidUTF8(v)) or binary[path] then
					chunk = chunk .. "<" .. self:base64Encode(v) .. ">"
				else
					chunk = chunk .. "\"" .. self:escapeString(v) .. "\""
				end
			end
		elseif type(v) == "number" then
			chunk = chunk .. tostring(v)
		elseif type(v) == "function" then
			table.insert(self.warnings, "Warning: Cannot insert function " .. path)
			return nil
		elseif type(v) == "boolean" then
			chunk = chunk .. tostring(v)
		elseif type(v) == "nil" then
			chunk = chunk .. "null"
		elseif type(v) == "table" then
			if self:isArray(v) then
				chunk = chunk .. "#("
				local newindent = indent
				if indent > -1 then
					newindent = indent + 1
				end
				chunk = self:encodeArray(v, chunk, newindent, path, binary)
			else
				chunk = chunk .. "@("
				local newindent = indent
				if indent > -1 then
					newindent = indent + 1
				end
				chunk = self:encodeMap(v, chunk, newindent, path, binary)
			end
			chunk = chunk .. indentString .. ")"
		else
			table.insert(self.warnings, "Warning: Cannot insert unknown type " .. type(v) .. " " .. path)
			return nil
		end

		return chunk

	end,

	--- Check a table for arrayness.
	-- @tparam table self This function is called as a method.
	-- @tparam table t The table to check for arrayness.
	-- @treturn bool Returns true if the table is an array. False if it is not.
	isArray = function(self, t)
		local i = 0
		for _ in pairs(t) do
			i = i + 1
			if t[i] == nil then return false end
		end
		return true
	end,

	--- Decode a Wexpr into a table.
	-- @tparam table self This function is called as a method.
	-- @tparam string chunk The Wexpr to be decoded.
	-- @tparam table table The prepopulated table to fill with additional values. Default is an empty table.
	-- @treturn any The value decoded from Wexpr.
	-- @treturn string The error message. Will equal nil if there was no error.
	decode = function(self, chunk, table)
		table = table or {}

		local decodeCall = function()
			self:newWexpr(chunk)
			self:tokenize()

			local token = self:nextToken()
			if self.tokens[token.type].getValue == nil then
				self:throw("Syntax Error: Expected definition to start with array(#) or map(@) or value but instead found " .. self.tokens[token.type].name .. ".", token.index, #token.token)
			end

			local table = self.tokens[token.type].getValue(self, table)

			if self.index < #self.tokenTable then
				local token = self:nextToken()
				self:throw("Syntax Error: Garbage at end of file.", token.index, #token.token)
			end

			return table

		end

		local status, result = pcall(decodeCall)
		if status then
			return result
		else
			if self.errormsg ~= "" then
				return nil, self.errormsg
			else
				return nil, result
			end
		end

	end,

	--- Decode a Map from the token table.
	-- @tparam table self This function is called as a method.
	-- @tparam table table The prepopulated table to fill with additional values. Default is an empty table.
	-- @treturn table the Map expressed as a lua table.
	decodeMap = function(self, table)

		while self:nextToken().type ~= self.tokensMap["close scope"] do

			local token = self:getToken()

			if token.type ~= self.tokensMap["word"] and token.type ~= self.tokensMap["number"] and token.type ~= self.tokensMap["string"] then
				self:throw("Syntax Error: Expected map key as word, number, or string but instead found " .. self.tokens[token.type].name .. ".", token.index, #token.token)
			end

			local key = self.tokens[token.type].getValue(self)
			if token.type == self.tokensMap["string"] then
				if not self:isValidUTF8(key) then
					self:throw("Syntax Error: Map key must be valid UTF-8 text.", token.index, #token.token)
				end
			end
			token = self:nextToken()

			if self.tokens[token.type].getValue == nil then
				self:throw("Syntax Error: Expected value for key " .. key .." but instead found " .. self.tokens[token.type].name .. ".", token.index, #token.token)
			end

			local subTable = nil
			if token.type == self.tokensMap["array"] or token.type == self.tokensMap["map"] then
				if type(table[key]) == "table" then
					subTable = table[key]
				else
					subTable = {}
				end

			end

			table[key] = self.tokens[token.type].getValue(self, subTable)

		end

		return table

	end,

	--- Decode an Array from the token table.
	-- @tparam table self This function is called as a method.
	-- @tparam table table The prepopulated table to fill with additional values. Default is an empty table.
	-- @treturn table the Array expressed as a lua table.
	decodeArray = function(self, table)

		local key = 1
		while self:nextToken().type ~= self.tokensMap["close scope"] do

			local token = self:getToken()

			if self.tokens[token.type].getValue == nil then
				self:throw("Syntax Error: Expected value for key " .. key .." but instead found " .. self.tokens[token.type].name .. ".", token.index, #token.token)
			end

			local subTable = nil
			if token.type == self.tokensMap["array"] or token.type == self.tokensMap["map"] then
				if type(table[key]) == "table" then
					subTable = table[key]
				else
					subTable = {}
				end

			end

			table[key] = self.tokens[token.type].getValue(self, subTable)
			key = key + 1
		end

		return table

	end,

	--- Take the chunk and turn it into a token table.
	-- @tparam table self This function is called as a method.
	tokenize = function(self)

		local i = 1
		while self.index <= #self.chunk do
			local index = self.index
			local tokenType, result = self:decodeToken()
			if self.tokens[tokenType].syntax then
				self.tokenTable[i] = {
					index = index,
					token = result,
					type = tokenType
				}
				i = i + 1
			end
		end

		self.index = 0

	end,

	--- Take the next token from the chunk and return it.
	-- @tparam table self This function is called as a method.
	-- @treturn number The type of token found.
	-- @treturn string the toke found expressed as string.
	-- @see tokens
	-- @see tokenTable
	decodeToken = function(self)
		if self.index > #self.chunk then
			return nil, "File ended unexpectedly."
		end

		for i=1, #self.tokens do
			local result = self.tokens[i].pattern(self, self.chunk, self.index)
			if result ~= nil then
				self.index = self.index + #result
				return i, result
			end
		end

		self:throw("Syntax error: Unknown token.", self.index)

	end,

	--- Create a new state for Wexpr decoding.
	-- Resets the state and generates the lines for the error and warning messages.
	-- @tparam table self This function is called as a method.
	-- @tparam string chunk The Wexpr to decode.
	-- @see throw
	-- @see warn
	-- @see chunkLines
	newWexpr = function(self, chunk)

		self.index = 1
		self.chunk = chunk
		self.warnings = {}
		self.errormsg = ""
		self.tokenTable = {}
		self.references = {}
		self.chunkLines = {}

		for l in (chunk.."\n"):gmatch("([^\n]-)[\n]") do
			l = l:gsub("\t", " ")
			table.insert(self.chunkLines, l)
		end

	end,

	--- Get the token at the index by offset.
	-- @tparam table self This function is called as a method.
	-- @tparam number offset The offset from the current index to get the token from.
	-- @treturn table The current token from the token table.
	-- @see tokens
	-- @see tokenTable
	getToken = function(self, offset)
		offset = offset or 0
		return self.tokenTable[self.index+offset]
	end,

	--- Get the next token in the token table.
	-- @tparam table self This function is called as a method.
	-- @treturn table The next token from the token table.
	-- @see tokens
	-- @see tokenTable
	nextToken = function(self)
		self.index = self.index + 1
		if self.index > #self.tokenTable then
			self:throw("Syntax Error: File ended unexpectedly.", #self.chunk)
		end
		return self.tokenTable[self.index]
	end,

	--- Convert and index to an actual line and position value.
	-- @tparam table self This function is called as a method.
	-- @tparam number index The index to convert.
	-- @treturn number The line number of the index.
	-- @treturn number The position in the line of the index.
	indexToLinePosition = function(self, index)

		local result = string.sub(self.chunk, 1, index)
		local _, count = string.gsub(result, "\n", "")
		local _, lineIndex = string.find(result, ".*[\n]")
		if lineIndex == nil then lineIndex = 0 end
		local position = #result - lineIndex
		local line = count + 1

		return line, position

	end

}

-- Initialize the libray.
libWexpr:init()

-- Return the library.
return libWexpr
