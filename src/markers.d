module markers;

import dparse.ast;

/**
 * The types of special token ranges identified by the parsing pass
 */
enum SpecialMarkerType
{
	/// Function declarations such as "const int foo();"
	functionAttributePrefix,
	/// Variable and parameter declarations such as "int bar[]"
	cStyleArray,
	/// The location of a closing brace for an interface, class, struct, union,
	/// or enum.
	bodyEnd
}

/**
 * Identifies ranges of tokens in the source tokens that need to be rewritten
 */
struct SpecialMarker
{
	/// Range type
	SpecialMarkerType type;

	/// Begin byte position (before relocateMarkers) or token index
	/// (after relocateMarkers)
	size_t index;

	/// The type suffix AST nodes that should be moved
	const(TypeSuffix[]) nodes;

	/// The function attribute such as const, immutable, or inout to move
	string functionAttribute;
}
