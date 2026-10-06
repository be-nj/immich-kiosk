package immich

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/damongolding/immich-kiosk/internal/cache"
	"github.com/damongolding/immich-kiosk/internal/config"
	"github.com/stretchr/testify/assert"
)

// stacksPayload mirrors the shape /api/stacks returns: whole assets per stack,
// with one of them named as the primary.
const stacksPayload = `[
  {
    "id": "stack-burst",
    "primaryAssetId": "burst-3",
    "assetCount": 5,
    "assets": [
      {"id": "burst-1", "originalFileName": "DSC_0001.jpg"},
      {"id": "burst-2", "originalFileName": "DSC_0002.jpg"},
      {"id": "burst-3", "originalFileName": "DSC_0003.jpg"},
      {"id": "burst-4", "originalFileName": "DSC_0004.jpg"},
      {"id": "burst-5", "originalFileName": "DSC_0005.jpg"}
    ]
  },
  {
    "id": "stack-raw",
    "primaryAssetId": "pair-jpeg",
    "assetCount": 2,
    "assets": [
      {"id": "pair-jpeg", "originalFileName": "IMG_1.jpg"},
      {"id": "pair-raw", "originalFileName": "IMG_1.dng"}
    ]
  }
]`

// stackTestServer serves a stacks listing and counts how often it was asked for.
func stackTestServer(t *testing.T, body string, status int) (*httptest.Server, *int) {
	t.Helper()

	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/stacks", r.URL.Path)
		calls++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)

	return server, &calls
}

func stackTestAsset(t *testing.T, serverURL, assetID string, base config.Config) *Asset {
	t.Helper()

	base.ImmichURL = serverURL
	base.ImmichAPIKey = "test-key"

	asset := New(context.Background(), base)
	asset.ID = assetID

	return &asset
}

// TestHasValidStackAgainstServer drives the real code path — HTTP call, JSON
// parse, child lookup — rather than the pure helper alone.
func TestHasValidStackAgainstServer(t *testing.T) {
	tests := []struct {
		name              string
		assetID           string
		showStackChildren bool
		want              bool
	}{
		{name: "stack primary is shown", assetID: "burst-3", want: true},
		{name: "burst child is skipped", assetID: "burst-1", want: false},
		{name: "last burst child is skipped", assetID: "burst-5", want: false},
		{name: "raw sidecar is skipped", assetID: "pair-raw", want: false},
		{name: "jpeg primary is shown", assetID: "pair-jpeg", want: true},
		{name: "unstacked asset is shown", assetID: "loose-asset", want: true},
		{name: "child is shown when children are wanted", assetID: "burst-1", showStackChildren: true, want: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cache.Initialize()

			server, calls := stackTestServer(t, stacksPayload, http.StatusOK)
			asset := stackTestAsset(t, server.URL, test.assetID, config.Config{
				ShowStackChildren: test.showStackChildren,
			})

			assert.Equal(t, test.want, asset.hasValidStack("test", "device"))

			if test.showStackChildren {
				assert.Zero(t, *calls, "no stack listing should be fetched when children are wanted")
			}
		})
	}
}

// TestStackListingIsCachedPerUser checks that one listing serves a whole pool,
// and that a different Immich user does not reuse it. Stacks belong to a user,
// so sharing the listing would filter one user's assets against another's stacks.
func TestStackListingIsCachedPerUser(t *testing.T) {
	cache.Initialize()

	server, calls := stackTestServer(t, stacksPayload, http.StatusOK)

	base := config.Config{}
	base.Kiosk.Cache = true

	for _, id := range []string{"burst-1", "burst-2", "pair-raw", "loose-asset"} {
		stackTestAsset(t, server.URL, id, base).hasValidStack("test", "device")
	}
	assert.Equal(t, 1, *calls, "the stack listing should be fetched once for the whole pool")

	otherUser := base
	otherUser.SelectedUser = "mareike"
	otherUser.ImmichUsersAPIKeys = map[string]string{"mareike": "mareike-key"}
	stackTestAsset(t, server.URL, "burst-1", otherUser).hasValidStack("test", "device")
	assert.Equal(t, 2, *calls, "a different user needs its own stack listing")
}

// TestStackListingNotCachedWhenCacheOff checks kiosk.cache is honoured, since it
// governs API call caching.
func TestStackListingNotCachedWhenCacheOff(t *testing.T) {
	cache.Initialize()

	server, calls := stackTestServer(t, stacksPayload, http.StatusOK)

	base := config.Config{}
	base.Kiosk.Cache = false

	for range 3 {
		stackTestAsset(t, server.URL, "burst-1", base).hasValidStack("test", "device")
	}
	assert.Equal(t, 3, *calls)
}

// TestStackFilterFailsOpen checks that an unusable stacks endpoint shows assets
// rather than emptying the slideshow.
func TestStackFilterFailsOpen(t *testing.T) {
	tests := []struct {
		name   string
		body   string
		status int
	}{
		{name: "server error", body: `{"error":"nope"}`, status: http.StatusInternalServerError},
		{name: "unparsable body", body: `not json`, status: http.StatusOK},
		{name: "empty listing", body: `[]`, status: http.StatusOK},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cache.Initialize()

			server, _ := stackTestServer(t, test.body, test.status)
			asset := stackTestAsset(t, server.URL, "burst-1", config.Config{})

			assert.True(t, asset.hasValidStack("test", "device"),
				"a child must still be shown when the stack listing is unusable")
		})
	}
}
