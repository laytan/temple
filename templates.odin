/* This file is generated by temple - DO NOT EDIT! */

package temple

import __temple_io "core:io"

compiled_inline :: compiled

/*
Returns the compiled template for the template file at the given path.

Use 'Compiled.with' to render the template into the given (recommended to be buffered) writer with 'this' set to the given T in the template.
Use 'Compiled.approx_bytes' to resize your buffered writer before calling.

**This procedure and file is generated based on your templates, if there is an error here, it most likely originates from your template.**
*/
compiled :: proc($path: string, $T: typeid) -> Compiled(T) {
	#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
}