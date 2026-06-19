package engineos

import (
	"bufio"
	"encoding/json"
	"os"
)

func ReadJSONL(path string) ([]map[string]any, error) {
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var records []map[string]any
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var record map[string]any
		if err := json.Unmarshal(line, &record); err != nil {
			return records, err
		}
		records = append(records, record)
	}
	return records, scanner.Err()
}
