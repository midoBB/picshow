import {
  Dialog,
  Flex,
  Text,
  Button,
  ScrollArea,
  Box,
  TextField,
  Checkbox,
} from "@radix-ui/themes";
import { useEffect, useState } from "react";
import { FolderIcon, ChevronRightIcon, FolderOpenIcon } from "lucide-react";
import "./FolderBrowserDialog.css";

interface DirectoryItem {
  name: string;
  path: string;
  is_dir: boolean;
}

interface FolderBrowserDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (path: string) => void;
  title?: string;
}

const FolderBrowserDialog = ({
  open,
  onOpenChange,
  onSelect,
  title = "Select Folder",
}: FolderBrowserDialogProps) => {
  const [currentPath, setCurrentPath] = useState("");
  const [items, setItems] = useState<DirectoryItem[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showHidden, setShowHidden] = useState(false);

  const fetchDirectoryContents = async (path: string) => {
    setIsLoading(true);
    setError(null);

    try {
      const response = await fetch("/api/browse", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ path, showHidden }),
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(
          errorData.error || "Failed to fetch directory contents",
        );
      }

      const data = await response.json();
      setItems(data.items || []);
      setCurrentPath(path);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unknown error occurred");
    } finally {
      setIsLoading(false);
    }
  };

  // Load initial directory on open
  useEffect(() => {
    if (open) {
      fetchDirectoryContents("");
    }
  }, [open]);

  // Re-fetch when showHidden changes
  useEffect(() => {
    if (open && currentPath !== "") {
      fetchDirectoryContents(currentPath);
    }
  }, [showHidden, open, currentPath]);

  const handleItemClick = (item: DirectoryItem) => {
    if (item.is_dir) {
      fetchDirectoryContents(item.path);
    }
  };

  const handleSelect = () => {
    // Make sure the path ends with a slash as required by your validation
    const formattedPath = currentPath.endsWith("/")
      ? currentPath
      : `${currentPath}/`;
    onSelect(formattedPath);
    onOpenChange(false);
  };

  const handleShowHiddenChange = () => {
    setShowHidden(!showHidden);
  };

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Content style={{ maxWidth: 600 }}>
        <Dialog.Title>{title}</Dialog.Title>

        <Flex direction="column" gap="3" my="3">
          <Flex justify="between" align="center">
            <TextField.Root value={currentPath} readOnly style={{ flexGrow: 1 }} />
            <Flex align="center" gap="2" ml="2">
              <Checkbox 
                id="showHidden" 
                checked={showHidden} 
                onCheckedChange={handleShowHiddenChange} 
              />
              <Text as="label" size="2" htmlFor="showHidden">
                Show Hidden
              </Text>
            </Flex>
          </Flex>

          {error && (
            <Text color="red" size="2">
              Error: {error}
            </Text>
          )}

          <Box
            style={{
              height: "300px",
              border: "1px solid var(--gray-6)",
              borderRadius: "var(--radius-2)",
            }}
          >
            <ScrollArea style={{ height: "100%" }}>
              {isLoading ? (
                <Flex
                  align="center"
                  justify="center"
                  style={{ height: "100%" }}
                >
                  <Text>Loading...</Text>
                </Flex>
              ) : items.length === 0 ? (
                <Flex
                  align="center"
                  justify="center"
                  style={{ height: "100%" }}
                >
                  <Text color="gray">No directories found</Text>
                </Flex>
              ) : (
                <Flex direction="column" gap="1" p="2">
                  {items.map((item, index) => (
                    <Flex
                      key={index}
                      align="center"
                      gap="2"
                      p="2"
                      style={{
                        cursor: "pointer",
                        borderRadius: "var(--radius-2)",
                      }}
                      className="folder-item"
                      onClick={() => handleItemClick(item)}
                    >
                      {item.name === ".." ? (
                        <FolderOpenIcon width="16" height="16" />
                      ) : (
                        <FolderIcon width="16" height="16" />
                      )}
                      <Text>{item.name}</Text>
                      {item.is_dir && item.name !== ".." && (
                        <ChevronRightIcon />
                      )}
                    </Flex>
                  ))}
                </Flex>
              )}
            </ScrollArea>
          </Box>
        </Flex>

        <Flex gap="3" justify="end" mt="4">
          <Dialog.Close>
            <Button variant="soft" color="gray">
              Cancel
            </Button>
          </Dialog.Close>
          <Button onClick={handleSelect} disabled={isLoading}>
            Select This Folder
          </Button>
        </Flex>
      </Dialog.Content>
    </Dialog.Root>
  );
};

export default FolderBrowserDialog;
