package immich

import (
	"encoding/json"
	"net/http"
	"net/url"
	"path"

	"charm.land/log/v2"
	"github.com/damongolding/immich-kiosk/internal/cache"
)

// StackAsset is the part of a stacked asset that matters here. The stacks
// endpoint hands back whole assets, but only the ID is needed to tell a stack's
// children from its primary.
type StackAsset struct {
	ID string `json:"id"`
}

// Stack is a group of related assets — a burst, or a raw and jpeg pair — with
// one of them marked as primary. Immich hides the rest behind it in its own
// timeline.
type Stack struct {
	ID             string       `json:"id"`
	PrimaryAssetID string       `json:"primaryAssetId"`
	Assets         []StackAsset `json:"assets"`
}

type Stacks []Stack

// stackChildIDs returns the IDs of every asset that sits in a stack without
// being its primary.
//
// Immich's own withStacked search flag cannot do this job. Setting it false
// drops every stacked asset, the primaries along with the children, leaving
// only assets in no stack at all. So the whole stack is fetched and the
// children are matched off against it here.
//
// The result is cached, since one listing covers every asset in a pool. Stacks
// belong to a user, so the cache key carries the selected user with it.
//
// A stack listing that cannot be fetched returns nil, which lets every asset
// through. A slideshow repeating a moment beats a slideshow showing nothing.
func (a *Asset) stackChildIDs(requestID, deviceID string) map[string]bool {
	var stacks Stacks

	u, err := url.Parse(a.requestConfig.ImmichURL)
	if err != nil {
		log.Error("parsing stacks url", "err", err)
		return nil
	}

	apiURL := url.URL{
		Scheme: u.Scheme,
		Host:   u.Host,
		Path:   path.Join("api", "stacks"),
	}

	cacheKey := cache.APICacheKey(apiURL.String(), deviceID, a.requestConfig.SelectedUser)

	if a.requestConfig.Kiosk.Cache {
		if cached, found := cache.Get(cacheKey); found {
			if children, ok := cached.(map[string]bool); ok {
				return children
			}
			log.Error(requestID + " stack cache type assertion failed")
		}
	}

	body, _, _, err := a.immichAPICall(a.ctx, http.MethodGet, apiURL.String(), nil)
	if err != nil {
		log.Error("fetching stacks", "err", err)
		return nil
	}

	if err = json.Unmarshal(body, &stacks); err != nil {
		log.Error("unmarshaling stacks", "err", err)
		return nil
	}

	children := childIDsFromStacks(stacks)

	log.Debug(requestID+" Fetched stacks", "stacks", len(stacks), "children", len(children))

	if a.requestConfig.Kiosk.Cache {
		cache.Set(cacheKey, children, a.requestConfig.Duration, a.requestConfig.CacheDuration)
	}

	return children
}

// childIDsFromStacks reduces a stack listing to the IDs of the assets that are
// not their stack's primary.
func childIDsFromStacks(stacks Stacks) map[string]bool {
	children := make(map[string]bool)

	for _, stack := range stacks {
		for _, asset := range stack.Assets {
			if asset.ID != stack.PrimaryAssetID {
				children[asset.ID] = true
			}
		}
	}

	return children
}
