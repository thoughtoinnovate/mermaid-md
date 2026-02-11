use regex::Regex;

#[derive(Debug, Clone)]
pub struct MermaidBlock {
    pub index: usize,
    pub code: String,
}

pub fn extract_mermaid_blocks(markdown: &str) -> Vec<MermaidBlock> {
    // Matches fenced blocks: ```mermaid\n ... \n```
    // Non-greedy match for content, handles multiple blocks.
    let re = Regex::new(r"(?s)```mermaid[ \t]*\r?\n(.*?)\r?\n```").unwrap();
    re.captures_iter(markdown)
        .enumerate()
        .map(|(i, caps)| MermaidBlock {
            index: i + 1,
            code: caps.get(1).map(|m| m.as_str()).unwrap_or("").to_string(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_block() {
        let md = "```mermaid\nflowchart TD\nA-->B\n```";
        let blocks = extract_mermaid_blocks(md);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].code.contains("flowchart TD"));
    }

    #[test]
    fn multiple_blocks() {
        let md = "```mermaid\nA-->B\n```\ntext\n```mermaid\nC-->D\n```";
        let blocks = extract_mermaid_blocks(md);
        assert_eq!(blocks.len(), 2);
        assert!(blocks[0].code.contains("A-->B"));
        assert!(blocks[1].code.contains("C-->D"));
    }

    #[test]
    fn ignores_non_mermaid_blocks() {
        let md = "```rust\nfn main() {}\n```";
        let blocks = extract_mermaid_blocks(md);
        assert_eq!(blocks.len(), 0);
    }

    #[test]
    fn no_blocks() {
        let md = "plain text only";
        let blocks = extract_mermaid_blocks(md);
        assert_eq!(blocks.len(), 0);
    }

    #[test]
    fn extracts_from_markdown_fixture_file() {
        let md = include_str!("../tests/fixtures/markdown_with_mermaid.md");
        let blocks = extract_mermaid_blocks(md);
        assert_eq!(blocks.len(), 2);
        assert!(blocks[0].code.contains("flowchart TD"));
        assert!(blocks[1].code.contains("sequenceDiagram"));
    }

    #[test]
    fn ignores_fixture_without_mermaid_blocks() {
        let md = include_str!("../tests/fixtures/markdown_without_mermaid.md");
        let blocks = extract_mermaid_blocks(md);
        assert!(blocks.is_empty());
    }
}
