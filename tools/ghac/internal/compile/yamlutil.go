package compile

import "gopkg.in/yaml.v3"

// mapGet returns the value node for key in a YAML mapping node, or nil.
func mapGet(n *yaml.Node, key string) *yaml.Node {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}

// mapDelete removes key from a YAML mapping node, if present.
func mapDelete(n *yaml.Node, key string) {
	if n == nil || n.Kind != yaml.MappingNode {
		return
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			n.Content = append(n.Content[:i], n.Content[i+2:]...)
			return
		}
	}
}

// mapKeys returns the ordered keys of a mapping node.
func mapKeys(n *yaml.Node) []string {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	out := make([]string, 0, len(n.Content)/2)
	for i := 0; i+1 < len(n.Content); i += 2 {
		out = append(out, n.Content[i].Value)
	}
	return out
}

func isScalarStr(n *yaml.Node) bool {
	return n != nil && n.Kind == yaml.ScalarNode
}

// stringList reads a node that GitHub allows as either a bare scalar or a
// sequence of scalars (e.g. `needs: build` vs `needs: [build, test]`).
func stringList(n *yaml.Node) []string {
	if n == nil {
		return nil
	}
	if n.Kind == yaml.ScalarNode {
		return []string{n.Value}
	}
	if n.Kind == yaml.SequenceNode {
		out := make([]string, 0, len(n.Content))
		for _, c := range n.Content {
			out = append(out, c.Value)
		}
		return out
	}
	return nil
}

// deepCopy clones a YAML node tree so per-job edits never disturb the
// original document (or sibling jobs' views of it).
func deepCopy(n *yaml.Node) *yaml.Node {
	if n == nil {
		return nil
	}
	cp := *n
	cp.Content = nil
	for _, c := range n.Content {
		cp.Content = append(cp.Content, deepCopy(c))
	}
	return &cp
}

func strNode(s string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: s}
}

func mappingNode(pairs ...*yaml.Node) *yaml.Node {
	return &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map", Content: pairs}
}
