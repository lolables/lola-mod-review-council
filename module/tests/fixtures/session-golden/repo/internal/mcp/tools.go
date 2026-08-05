package mcp

import "encoding/json"

func handleCreate(b []byte) error {
	var req createReq
	if err := json.Unmarshal(b, &req); err != nil {
		return err
	}
	return store.Put(req)
}

func handleUpdate(b []byte) error {
	var req updateReq
	if err := json.Unmarshal(b, &req); err != nil {
		return err
	}
	return store.Patch(req)
}

func handleDelete(b []byte) error {
	var req deleteReq
	if err := json.Unmarshal(b, &req); err != nil {
		return err
	}
	return store.Drop(req)
}
