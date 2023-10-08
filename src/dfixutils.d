module dfixutils;

/**
 * Prints help message
 */
void printHelp()
{
	import std.stdio : stdout;

	stdout.writeln(`
Dfix automatically upgrades D source code to comply with new language changes.
Files are modified in place, so have backup copies ready or use a source
control system.

Usage:

    dfix [Options] FILES DIRECTORIES

Options:

    --dip64
        Rewrites attributes to be compliant with DIP64. This defaults to
        "false". Do not use this feature if you want your code to compile.
		It exists as a proof-of-concept for enabling DIP64.
    --dip65
        Rewrites catch blocks to be compliant with DIP65. This defaults to
        "true". Use --dip65=false to disable this fix.
    --dip1003
        Rewrites body blocks to be compliant with DIP1003. This defaults to
        "true". Use --dip1003=false to disable this fix.
    --help -h
        Prints this help message
`);
}

/**
 * Dummy message output function for the lexer/parser
 */
void reportErrors(string fileName, size_t lineNumber, size_t columnNumber, string message, bool isError)
{
	import std.stdio : stderr;

	if (!isError)
		return;

	stderr.writefln("%s(%d:%d)[error]: %s", fileName, lineNumber, columnNumber, message);
}
