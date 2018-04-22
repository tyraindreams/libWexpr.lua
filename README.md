# libWexpr.lua

libWexpr.lua is a [Wexpr](https://github.com/thothonegan/libWexpr) file decoder and encoder libray for lua which can convert a standards compliant text format Wexpr file into a lua table/variable or convert a lua table/variable into a standards compliant text format Wexpr file.

### Features

  - Should work with lua 5.1 and luajit 2.0 and newer.
  - Automatically validates strings for UTF-8 when encoding; Switches to base64 binary value when required automatically.
  - Automatically tests arrayness and encodes tables which are linear arrays as Wexpr arrays.
  - Can force a string value to be encoded as binary data by providing a table of paths.
  - Can encode with pretty print enabled or disabled.
  - Automatically decodes true, false, null, and nil barewords as their native lua counterparts and will not encode strings containing these words as barewords.
  - Can decode into a prepopulated table.
  - Easy to read error and warning messages in a clang-like format.
```
1:5:Syntax Error: Reference [b] is undefined.
@(a *[b])
    ^~~~
    
1:3:Syntax Error: Expected map key as word, number, or string but instead found array.
@(#() asdf) 
  ^~
  
1:7:Syntax Error: Invalid escape sequence in string.
"asdf \a"
      ^~
```

### Usage

This example covers most of the usages of the library.

```lua
-- Require into table.
wexpr = require("libWexpr")

-- A string containing a valid Wexpr expression.
chunk = "#(1 2 3 4 5)"

--- Create the optional prepopulated table and add some existing values.
luaTable = {}
luaTable[6] = "String"
luaTable[4] = 5

-- Call decode by providing it a string containing the Wexpr text. You can optionally provide a pre-populated table for it to fill out with new information as a second argument; if one is not provided it will create a new table.
result, errormsg = wexpr:decode(chunk, luaTable)
-- This will return the equivalent of of the lua {1, 2, 3, 4, 5, "String"} overwriting the 4th index with the 4 from the Wexpr chunk but ignoring the 6th position which was set to "String" in the prepopulated tabled.

-- If errormsg is not nil then an error occured and errormsg will contain the error as a string. Otherwise result will contain the contents of the Wexpr text chunk in native lua format. You MUST check against the second return value as nil is a valid result of decoding a Wexpr file.
if errormsg ~= nil then
   print("DECODE FAIL")
   print(errormsg)
else
   print("DECODE SUCCESS")
end

-- A table to encode into Wexpr.
luaTable = {key1 = "string", key2 = "hi", key3 = true, key4 = {1, 2, 3}, key5 = "foo"}

-- Call encode by providing it table or variable. The second and third parameters are optional. The second parameter is pretty print and defaults to false. The third parameter is a table of keys that give the paths to all keys that should be encoded as base64 binary in the output file if they are strings. The paths are stem from the root table which is expressed as '-' so -.key1 would equate to luaTable.key1 in this example.
result, errormsg = wexpr:encode(luaTable, true, {["-.key1"] = true, ["-.key2"] = true })

-- This will return:
--[[
@(
	key3 true
	key1 <c3RyaW5n>
	key5 foo
	key2 <aGk=>
	key4 #(
		1
		2
		3
	)
)
]]

-- The same rules apply for error checking with the encode function.
if errormsg ~= nil then
   print("ENCODE FAIL")
   print(errormsg)
else
   print("ENCODE SUCCESS")
   print(result)
end
```
